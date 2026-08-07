from __future__ import annotations

import json
import sqlite3
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np

from ailbum.metadata import ImageMetadata
from ailbum.models import PersonRecord, PhotoRecord

SCHEMA_VERSION = 2

SCHEMA = """
CREATE TABLE IF NOT EXISTS images (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    source_root TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    extension TEXT NOT NULL,
    file_size_bytes INTEGER NOT NULL,
    modified_at TEXT NOT NULL,
    created_at TEXT,
    sha256 TEXT NOT NULL,
    mime_type TEXT,
    image_format TEXT,
    color_mode TEXT,
    width INTEGER,
    height INTEGER,
    frame_count INTEGER,
    orientation INTEGER,
    taken_at TEXT,
    camera_make TEXT,
    camera_model TEXT,
    lens_model TEXT,
    software TEXT,
    gps_latitude REAL,
    gps_longitude REAL,
    gps_altitude REAL,
    exif_json TEXT NOT NULL,
    container_metadata_json TEXT NOT NULL,
    extraction_error TEXT,
    indexed_at TEXT NOT NULL,
    missing INTEGER NOT NULL DEFAULT 0 CHECK (missing IN (0, 1))
);

CREATE INDEX IF NOT EXISTS idx_images_sha256 ON images(sha256);
CREATE INDEX IF NOT EXISTS idx_images_taken_at ON images(taken_at);
CREATE INDEX IF NOT EXISTS idx_images_camera ON images(camera_make, camera_model);
CREATE INDEX IF NOT EXISTS idx_images_source_root ON images(source_root);

CREATE TABLE IF NOT EXISTS analysis_runs (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    output TEXT NOT NULL,
    started_at TEXT NOT NULL,
    completed_at TEXT NOT NULL,
    face_backend TEXT NOT NULL,
    config_json TEXT NOT NULL,
    summary_json TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('completed', 'failed'))
);

CREATE TABLE IF NOT EXISTS photo_analysis (
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
    photo_id TEXT NOT NULL,
    sharpness REAL NOT NULL,
    exposure REAL NOT NULL,
    quality REAL NOT NULL,
    is_blurry INTEGER NOT NULL CHECK (is_blurry IN (0, 1)),
    similar_cluster INTEGER,
    selected INTEGER NOT NULL CHECK (selected IN (0, 1)),
    error TEXT,
    PRIMARY KEY (run_id, image_id),
    UNIQUE (run_id, photo_id)
);

CREATE INDEX IF NOT EXISTS idx_photo_analysis_selected ON photo_analysis(run_id, selected);
CREATE INDEX IF NOT EXISTS idx_photo_analysis_similar ON photo_analysis(run_id, similar_cluster);

CREATE TABLE IF NOT EXISTS people (
    id INTEGER PRIMARY KEY,
    public_id TEXT NOT NULL UNIQUE,
    name TEXT,
    embedding_model TEXT NOT NULL,
    centroid_embedding BLOB NOT NULL,
    embedding_dim INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_people_name ON people(name);
CREATE INDEX IF NOT EXISTS idx_people_model ON people(embedding_model);

CREATE TABLE IF NOT EXISTS faces (
    id INTEGER PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
    face_id TEXT NOT NULL,
    face_index INTEGER NOT NULL,
    bbox_x INTEGER NOT NULL,
    bbox_y INTEGER NOT NULL,
    bbox_width INTEGER NOT NULL,
    bbox_height INTEGER NOT NULL,
    confidence REAL NOT NULL,
    person_cluster INTEGER,
    person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
    embedding BLOB,
    embedding_dim INTEGER,
    embedding_model TEXT,
    UNIQUE (run_id, face_id)
);

CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(run_id, person_cluster);
CREATE INDEX IF NOT EXISTS idx_faces_person_id ON faces(person_id);
CREATE INDEX IF NOT EXISTS idx_faces_image ON faces(image_id);
"""


@contextmanager
def connect(database: Path) -> Iterator[sqlite3.Connection]:
    database.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.executescript(SCHEMA)
    connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def index_metadata(
    database: Path, source: Path, metadata: list[ImageMetadata]
) -> dict[str, int]:
    source_root = str((source if source.is_dir() else source.parent).resolve())
    with connect(database) as connection:
        connection.execute("UPDATE images SET missing = 1 WHERE source_root = ?", (source_root,))
        for item in metadata:
            _upsert_image(connection, item)
        counts = connection.execute(
            """
            SELECT COUNT(*) AS images,
                   SUM(CASE WHEN missing = 0 THEN 1 ELSE 0 END) AS available,
                   SUM(CASE WHEN extraction_error IS NOT NULL THEN 1 ELSE 0 END) AS errors
            FROM images
            """
        ).fetchone()
    return {key: int(counts[key] or 0) for key in ("images", "available", "errors")}


def save_analysis(
    database: Path,
    source: Path,
    output: Path,
    manifest: dict[str, object],
    records: list[PhotoRecord],
    people: list[PersonRecord],
    metadata: list[ImageMetadata],
    face_similarity: float,
) -> str:
    run_id = str(manifest["run_id"])
    with connect(database) as connection:
        source_root = str((source if source.is_dir() else source.parent).resolve())
        connection.execute("UPDATE images SET missing = 1 WHERE source_root = ?", (source_root,))
        image_ids: dict[str, int] = {}
        for item in metadata:
            image_ids[item.path] = _upsert_image(connection, item)
        connection.execute(
            """
            INSERT INTO analysis_runs (
                id, source, output, started_at, completed_at, face_backend,
                config_json, summary_json, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'completed')
            """,
            (
                run_id,
                str(source.resolve()),
                str(output.resolve()),
                str(manifest["started_at"]),
                str(manifest["generated_at"]),
                str(manifest["face_backend"]),
                _json(manifest["config"]),
                _json(manifest["summary"]),
            ),
        )
        _assign_people(connection, people, records, face_similarity)
        for record in records:
            image_id = image_ids[record.path]
            connection.execute(
                """
                INSERT INTO photo_analysis (
                    run_id, image_id, photo_id, sharpness, exposure, quality,
                    is_blurry, similar_cluster, selected, error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    run_id,
                    image_id,
                    record.photo_id,
                    record.sharpness,
                    record.exposure,
                    record.quality,
                    int(record.is_blurry),
                    record.similar_cluster,
                    int(record.selected),
                    record.error,
                ),
            )
            for face_index, face in enumerate(record.faces, start=1):
                x, y, width, height = face.bbox
                connection.execute(
                    """
                    INSERT INTO faces (
                        run_id, image_id, face_id, face_index, bbox_x, bbox_y,
                        bbox_width, bbox_height, confidence, person_cluster,
                        person_id, embedding, embedding_dim, embedding_model
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        run_id,
                        image_id,
                        face.face_id,
                        face_index,
                        x,
                        y,
                        width,
                        height,
                        face.confidence,
                        face.person_cluster,
                        face.person_id,
                        _encode_embedding(face.embedding),
                        len(face.embedding) if face.embedding else None,
                        _embedding_model_for_person(people, face.person_cluster),
                    ),
                )
                face.database_id = int(connection.execute("SELECT last_insert_rowid()").fetchone()[0])
                if face.person_id is not None:
                    connection.execute(
                        """
                        UPDATE faces
                        SET person_id = ?
                        WHERE person_id IS NULL AND image_id = ?
                          AND bbox_x = ? AND bbox_y = ?
                          AND bbox_width = ? AND bbox_height = ?
                        """,
                        (face.person_id, image_id, x, y, width, height),
                    )
        for person in people:
            if person.person_id is not None:
                _refresh_person_centroid(connection, person.person_id)
    return run_id


def _assign_people(
    connection: sqlite3.Connection,
    people: list[PersonRecord],
    records: list[PhotoRecord],
    similarity_threshold: float,
) -> None:
    existing = [dict(row) for row in connection.execute("SELECT * FROM people").fetchall()]
    cluster_people: dict[int, int] = {}
    for person in people:
        centroid = np.asarray(person.centroid, dtype=np.float32)
        compatible = [
            row
            for row in existing
            if row["embedding_model"] == person.embedding_model
            and row["embedding_dim"] == centroid.size
        ]
        best: dict[str, Any] | None = None
        best_similarity = -1.0
        for candidate in compatible:
            candidate_centroid = _decode_embedding(
                candidate["centroid_embedding"], candidate["embedding_dim"]
            )
            similarity = float(np.dot(centroid, candidate_centroid))
            if similarity > best_similarity:
                best = candidate
                best_similarity = similarity
        now = utc_now()
        if best is not None and best_similarity >= similarity_threshold:
            person.person_id = int(best["id"])
            person.public_id = str(best["public_id"])
            person.name = best["name"]
        else:
            public_id = str(uuid.uuid4())
            cursor = connection.execute(
                """
                INSERT INTO people (
                    public_id, name, embedding_model, centroid_embedding,
                    embedding_dim, created_at, updated_at
                ) VALUES (?, NULL, ?, ?, ?, ?, ?)
                """,
                (
                    public_id,
                    person.embedding_model,
                    _encode_embedding(person.centroid),
                    len(person.centroid),
                    now,
                    now,
                ),
            )
            person.person_id = int(cursor.lastrowid)
            person.public_id = public_id
        cluster_people[person.cluster_id] = person.person_id

    for record in records:
        for face in record.faces:
            if face.person_cluster is not None:
                face.person_id = cluster_people[face.person_cluster]


def _refresh_person_centroid(connection: sqlite3.Connection, person_id: int) -> None:
    person = connection.execute(
        "SELECT embedding_model FROM people WHERE id = ?", (person_id,)
    ).fetchone()
    if person is None:
        return
    rows = connection.execute(
        """
        SELECT embedding, embedding_dim
        FROM faces
        WHERE person_id = ? AND embedding_model = ? AND embedding IS NOT NULL
        """,
        (person_id, person["embedding_model"]),
    ).fetchall()
    if not rows:
        return
    embeddings = [_decode_embedding(row["embedding"], row["embedding_dim"]) for row in rows]
    centroid = np.mean(embeddings, axis=0)
    norm = float(np.linalg.norm(centroid))
    if norm > 0:
        centroid = centroid / norm
    connection.execute(
        """
        UPDATE people
        SET centroid_embedding = ?, embedding_dim = ?, updated_at = ?
        WHERE id = ?
        """,
        (_encode_embedding(centroid.tolist()), centroid.size, utc_now(), person_id),
    )


def database_summary(database: Path) -> dict[str, Any]:
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        image_counts = connection.execute(
            """
            SELECT COUNT(*) AS images,
                   SUM(CASE WHEN missing = 0 THEN 1 ELSE 0 END) AS available,
                   COUNT(DISTINCT sha256) AS unique_files,
                   SUM(file_size_bytes) AS bytes,
                   SUM(CASE WHEN gps_latitude IS NOT NULL THEN 1 ELSE 0 END) AS with_gps,
                   SUM(CASE WHEN taken_at IS NOT NULL THEN 1 ELSE 0 END) AS with_taken_at
            FROM images
            """
        ).fetchone()
        runs = connection.execute("SELECT COUNT(*) FROM analysis_runs").fetchone()[0]
        faces = connection.execute("SELECT COUNT(*) FROM faces").fetchone()[0]
        linked_faces = connection.execute(
            "SELECT COUNT(*) FROM faces WHERE person_id IS NOT NULL"
        ).fetchone()[0]
        people = connection.execute("SELECT COUNT(*) FROM people").fetchone()[0]
    count_fields = ("images", "available", "unique_files", "bytes", "with_gps", "with_taken_at")
    result = {key: int(image_counts[key] or 0) for key in count_fields}
    result.update(
        {
            "analysis_runs": int(runs),
            "faces": int(faces),
            "linked_faces": int(linked_faces),
            "people": int(people),
        }
    )
    return result


def list_catalog_images(database: Path, limit: int = 100) -> list[dict[str, Any]]:
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        rows = connection.execute(
            """
            SELECT id, path, taken_at, width, height, camera_make, camera_model,
                   gps_latitude, gps_longitude, file_size_bytes, missing
            FROM images
            ORDER BY COALESCE(taken_at, modified_at), path
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


def get_catalog_image(database: Path, image_id: int) -> dict[str, Any]:
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        row = connection.execute("SELECT * FROM images WHERE id = ?", (image_id,)).fetchone()
        if row is None:
            raise ValueError(f"Image id does not exist: {image_id}")
        result = dict(row)
        result["exif"] = json.loads(result.pop("exif_json"))
        result["container_metadata"] = json.loads(result.pop("container_metadata_json"))
        result["analysis_history"] = [
            dict(item)
            for item in connection.execute(
                """
                SELECT pa.*, ar.started_at, ar.completed_at, ar.face_backend
                FROM photo_analysis AS pa
                JOIN analysis_runs AS ar ON ar.id = pa.run_id
                WHERE pa.image_id = ?
                ORDER BY ar.completed_at DESC
                """,
                (image_id,),
            ).fetchall()
        ]
        result["faces"] = [
            dict(item)
            for item in connection.execute(
                """
                SELECT f.id, f.run_id, f.image_id, f.face_id, f.face_index,
                       f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                       f.confidence, f.person_cluster, f.person_id,
                       f.embedding_dim, f.embedding_model,
                       p.public_id AS person_public_id, p.name AS person_name
                FROM faces AS f
                LEFT JOIN people AS p ON p.id = f.person_id
                WHERE f.image_id = ?
                ORDER BY f.run_id, f.face_index
                """,
                (image_id,),
            ).fetchall()
        ]
    return result


def list_people(database: Path, limit: int = 100) -> list[dict[str, Any]]:
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        rows = connection.execute(
            """
            SELECT p.id, p.public_id, p.name, p.embedding_model,
                   COUNT(f.id) AS face_count,
                   COUNT(DISTINCT f.image_id) AS photo_count,
                   p.created_at, p.updated_at
            FROM people AS p
            LEFT JOIN faces AS f ON f.person_id = p.id
            GROUP BY p.id
            ORDER BY photo_count DESC, face_count DESC, p.id
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(row) for row in rows]


def get_person(database: Path, person_id: int) -> dict[str, Any]:
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        row = connection.execute(
            """
            SELECT p.id, p.public_id, p.name, p.embedding_model,
                   p.embedding_dim, p.created_at, p.updated_at,
                   COUNT(f.id) AS face_count,
                   COUNT(DISTINCT f.image_id) AS photo_count
            FROM people AS p
            LEFT JOIN faces AS f ON f.person_id = p.id
            WHERE p.id = ?
            GROUP BY p.id
            """,
            (person_id,),
        ).fetchone()
        if row is None:
            raise ValueError(f"Person id does not exist: {person_id}")
        result = dict(row)
        result["faces"] = [
            dict(item)
            for item in connection.execute(
                """
                SELECT f.id, f.run_id, f.face_id, f.face_index, f.image_id,
                       f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                       f.confidence, f.person_cluster, f.embedding_model,
                       i.path, i.taken_at, i.width AS image_width,
                       i.height AS image_height
                FROM faces AS f
                JOIN images AS i ON i.id = f.image_id
                WHERE f.person_id = ?
                ORDER BY COALESCE(i.taken_at, i.modified_at), i.path, f.face_index
                """,
                (person_id,),
            ).fetchall()
        ]
    return result


def name_person(database: Path, person_id: int, name: str | None) -> dict[str, Any]:
    normalized = name.strip() if name else None
    with connect(database) as connection:
        cursor = connection.execute(
            "UPDATE people SET name = ?, updated_at = ? WHERE id = ?",
            (normalized or None, utc_now(), person_id),
        )
        if cursor.rowcount == 0:
            raise ValueError(f"Person id does not exist: {person_id}")
    return get_person(database, person_id)


def merge_people(database: Path, target_id: int, source_ids: list[int]) -> dict[str, Any]:
    sources = sorted(set(source_ids) - {target_id})
    if not sources:
        raise ValueError("At least one different source person is required")
    with connect(database) as connection:
        target = connection.execute("SELECT id FROM people WHERE id = ?", (target_id,)).fetchone()
        if target is None:
            raise ValueError(f"Person id does not exist: {target_id}")
        placeholders = ", ".join("?" for _ in sources)
        rows = connection.execute(
            f"SELECT id FROM people WHERE id IN ({placeholders})", sources
        ).fetchall()
        found = {int(row["id"]) for row in rows}
        missing = sorted(set(sources) - found)
        if missing:
            raise ValueError(f"Person ids do not exist: {missing}")
        connection.execute(
            f"UPDATE faces SET person_id = ? WHERE person_id IN ({placeholders})",
            [target_id, *sources],
        )
        connection.execute(f"DELETE FROM people WHERE id IN ({placeholders})", sources)
        _refresh_person_centroid(connection, target_id)
    return get_person(database, target_id)


def new_run_id() -> str:
    return str(uuid.uuid4())


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _upsert_image(connection: sqlite3.Connection, item: ImageMetadata) -> int:
    values = item.to_dict()
    values.update(
        {
            "exif_json": _json(values.pop("exif")),
            "container_metadata_json": _json(values.pop("container_metadata")),
            "indexed_at": utc_now(),
            "missing": 0,
        }
    )
    columns = list(values)
    parameters = list(values.values())
    placeholders = ", ".join("?" for _ in columns)
    updates = ", ".join(
        f"{column} = excluded.{column}" for column in columns if column not in {"path"}
    )
    connection.execute(
        f"""
        INSERT INTO images ({', '.join(columns)}) VALUES ({placeholders})
        ON CONFLICT(path) DO UPDATE SET {updates}
        """,
        parameters,
    )
    row = connection.execute("SELECT id FROM images WHERE path = ?", (item.path,)).fetchone()
    assert row is not None
    return int(row["id"])


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _encode_embedding(embedding: list[float] | None) -> bytes | None:
    if not embedding:
        return None
    return np.asarray(embedding, dtype=np.float32).tobytes()


def _decode_embedding(value: bytes, dimension: int) -> np.ndarray:
    embedding = np.frombuffer(value, dtype=np.float32, count=dimension).copy()
    norm = float(np.linalg.norm(embedding))
    return embedding / norm if norm > 0 else embedding


def _embedding_model_for_person(
    people: list[PersonRecord], cluster_id: int | None
) -> str | None:
    for person in people:
        if person.cluster_id == cluster_id:
            return person.embedding_model
    return None
