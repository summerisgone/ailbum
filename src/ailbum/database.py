from __future__ import annotations

import json
import sqlite3
import uuid
from collections import defaultdict
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import numpy as np

from ailbum.migrations import migrate_v12
from ailbum.metadata import ImageMetadata, _filename_taken_at
from ailbum.models import PersonRecord, PhotoRecord, StoryRecord
from ailbum.stories import STORY_ALGORITHM_VERSION, StoryPhoto, detect_stories
from ailbum.story_naming import StoryNamer

SCHEMA_VERSION = 12

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
    availability TEXT NOT NULL DEFAULT 'present'
        CHECK (availability IN ('present', 'missing', 'archived'))
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
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    photo_id TEXT NOT NULL,
    sharpness REAL NOT NULL,
    exposure REAL NOT NULL,
    quality REAL NOT NULL,
    aesthetic_score REAL,
    composition_score REAL,
    rule_of_thirds REAL,
    frame_occupancy REAL,
    negative_space REAL,
    crop_risk REAL,
    color_balance REAL,
    color_harmony REAL,
    main_subject_json TEXT,
    scene_tags_json TEXT NOT NULL DEFAULT '[]',
    object_tags_json TEXT NOT NULL DEFAULT '[]',
    vision_embedding BLOB,
    vision_embedding_dim INTEGER,
    vision_embedding_model TEXT,
    is_blurry INTEGER NOT NULL CHECK (is_blurry IN (0, 1)),
    similar_cluster INTEGER,
    story_id INTEGER,
    selected INTEGER NOT NULL CHECK (selected IN (0, 1)),
    error TEXT,
    PRIMARY KEY (run_id, image_id),
    UNIQUE (run_id, photo_id)
);

CREATE INDEX IF NOT EXISTS idx_photo_analysis_selected ON photo_analysis(run_id, selected);
CREATE INDEX IF NOT EXISTS idx_photo_analysis_similar ON photo_analysis(run_id, similar_cluster);

CREATE TABLE IF NOT EXISTS stories (
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    story_id INTEGER NOT NULL,
    title TEXT NOT NULL,
    started_at TEXT,
    ended_at TEXT,
    representative_image_id INTEGER REFERENCES images(id) ON DELETE SET NULL,
    scene_tags_json TEXT NOT NULL DEFAULT '[]',
    object_tags_json TEXT NOT NULL DEFAULT '[]',
    naming_model TEXT,
    algorithm_version INTEGER NOT NULL DEFAULT 2,
    PRIMARY KEY (run_id, story_id)
);

CREATE INDEX IF NOT EXISTS idx_stories_time ON stories(run_id, started_at);

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
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
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
    left_eye_state TEXT CHECK (left_eye_state IN ('open', 'closed') OR left_eye_state IS NULL),
    right_eye_state TEXT CHECK (right_eye_state IN ('open', 'closed') OR right_eye_state IS NULL),
    left_eye_open_probability REAL,
    right_eye_open_probability REAL,
    both_eyes_open INTEGER CHECK (both_eyes_open IN (0, 1) OR both_eyes_open IS NULL),
    expression TEXT,
    expression_confidence REAL,
    smile_probability REAL,
    expression_scores_json TEXT,
    UNIQUE (run_id, face_id)
);

CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(run_id, person_cluster);
CREATE INDEX IF NOT EXISTS idx_faces_person_id ON faces(person_id);
CREATE INDEX IF NOT EXISTS idx_faces_image ON faces(image_id);

CREATE TABLE IF NOT EXISTS albums (
    id INTEGER PRIMARY KEY,
    public_id TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    purpose TEXT NOT NULL DEFAULT 'photobook_demo'
        CHECK (purpose IN ('photobook_demo', 'print')),
    status TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'ordered', 'archived')),
    target_count INTEGER NOT NULL DEFAULT 24 CHECK (target_count > 0),
    run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
    ordered_at TEXT,
    archived_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS album_sources (
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    source_root TEXT NOT NULL,
    PRIMARY KEY (album_id, source_root)
);

CREATE TABLE IF NOT EXISTS album_photos (
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    position INTEGER NOT NULL,
    added_at TEXT NOT NULL,
    PRIMARY KEY (album_id, image_id)
);

CREATE INDEX IF NOT EXISTS idx_album_photos_order ON album_photos(album_id, position);

CREATE TABLE IF NOT EXISTS album_exports (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    layout_id INTEGER,
    selection_hash TEXT NOT NULL,
    folder TEXT NOT NULL,
    count INTEGER NOT NULL,
    missing_json TEXT NOT NULL DEFAULT '[]',
    exported_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS selection_events (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    run_id TEXT REFERENCES analysis_runs(id) ON DELETE SET NULL,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    action TEXT NOT NULL CHECK (action IN ('add', 'remove', 'seed')),
    source TEXT NOT NULL CHECK (source IN ('auto', 'manual', 'backfill')),
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_selection_events_album ON selection_events(album_id, id);

CREATE TABLE IF NOT EXISTS ranking_models (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('pairwise', 'pointwise')),
    feature_version INTEGER NOT NULL,
    model_json TEXT NOT NULL,
    metrics_json TEXT NOT NULL DEFAULT '{}',
    active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1)),
    trained_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS image_object_scans (
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
    detector_model TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    objects_json TEXT NOT NULL,
    scanned_at TEXT NOT NULL,
    PRIMARY KEY (image_id, detector_model)
);

CREATE TABLE IF NOT EXISTS layouts (
    id INTEGER PRIMARY KEY,
    album_id INTEGER NOT NULL UNIQUE REFERENCES albums(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
    prompt TEXT,
    orientation TEXT NOT NULL,
    spread_count INTEGER NOT NULL,
    min_photos INTEGER NOT NULL,
    max_photos INTEGER NOT NULL,
    selection_hash TEXT NOT NULL,
    assistant_model TEXT,
    unplaced_json TEXT NOT NULL DEFAULT '[]',
    warnings_json TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS layout_spreads (
    id INTEGER PRIMARY KEY,
    layout_id INTEGER NOT NULL REFERENCES layouts(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    template_id TEXT NOT NULL,
    story_ids_json TEXT NOT NULL DEFAULT '[]',
    warnings_json TEXT NOT NULL DEFAULT '[]',
    assistant_reason TEXT,
    UNIQUE (layout_id, position)
);

CREATE TABLE IF NOT EXISTS layout_placements (
    spread_id INTEGER NOT NULL REFERENCES layout_spreads(id) ON DELETE CASCADE,
    cell_index INTEGER NOT NULL,
    image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE RESTRICT,
    crop_x REAL NOT NULL,
    crop_y REAL NOT NULL,
    crop_w REAL NOT NULL,
    crop_h REAL NOT NULL,
    fit REAL NOT NULL,
    warnings_json TEXT NOT NULL DEFAULT '[]',
    replaced_image_id INTEGER,
    PRIMARY KEY (spread_id, cell_index)
);
"""


@contextmanager
def connect(database: Path) -> Iterator[sqlite3.Connection]:
    database.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.executescript(SCHEMA)
    _migrate_schema(connection)
    if any(row[1] == "missing" for row in connection.execute("PRAGMA table_info(images)")):
        migrate_v12(connection)
    connection.execute(
        "CREATE INDEX IF NOT EXISTS idx_images_availability ON images(availability)"
    )
    connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def mark_source_missing(connection: sqlite3.Connection, source_root: str) -> None:
    connection.execute(
        "UPDATE images SET availability = 'missing' "
        "WHERE source_root = ? AND availability = 'present'",
        (source_root,),
    )


def index_metadata(
    database: Path, source: Path, metadata: list[ImageMetadata]
) -> dict[str, int]:
    source_root = str((source if source.is_dir() else source.parent).resolve())
    with connect(database) as connection:
        mark_source_missing(connection, source_root)
        for item in metadata:
            _upsert_image(connection, item)
        counts = connection.execute(
            """
            SELECT COUNT(*) AS images,
                   SUM(CASE WHEN availability = 'present' THEN 1 ELSE 0 END) AS available,
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
    stories: list[StoryRecord] | None = None,
) -> str:
    run_id = str(manifest["run_id"])
    with connect(database) as connection:
        source_root = str((source if source.is_dir() else source.parent).resolve())
        mark_source_missing(connection, source_root)
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
                    aesthetic_score, composition_score, rule_of_thirds,
                    frame_occupancy, negative_space, crop_risk, color_balance,
                    color_harmony, main_subject_json, scene_tags_json,
                    object_tags_json, vision_embedding, vision_embedding_dim,
                    vision_embedding_model, is_blurry, similar_cluster, story_id,
                    selected, error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    run_id,
                    image_id,
                    record.photo_id,
                    record.sharpness,
                    record.exposure,
                    record.quality,
                    (
                        record.semantics.aesthetic_score
                        if record.semantics is not None
                        else None
                    ),
                    record.composition.score if record.composition is not None else None,
                    (
                        record.composition.rule_of_thirds
                        if record.composition is not None
                        else None
                    ),
                    (
                        record.composition.frame_occupancy
                        if record.composition is not None
                        else None
                    ),
                    (
                        record.composition.negative_space
                        if record.composition is not None
                        else None
                    ),
                    record.composition.crop_risk if record.composition is not None else None,
                    record.color.balance if record.color is not None else None,
                    record.color.harmony if record.color is not None else None,
                    (
                        _json(asdict(record.composition.main_subject))
                        if record.composition is not None
                        and record.composition.main_subject is not None
                        else None
                    ),
                    _json(
                        [asdict(tag) for tag in record.semantics.scenes]
                        if record.semantics is not None
                        else []
                    ),
                    _json(
                        [asdict(tag) for tag in record.semantics.objects]
                        if record.semantics is not None
                        else []
                    ),
                    _encode_embedding(
                        record.semantics.embedding if record.semantics is not None else None
                    ),
                    (
                        len(record.semantics.embedding)
                        if record.semantics is not None and record.semantics.embedding
                        else None
                    ),
                    record.semantics.model if record.semantics is not None else None,
                    int(record.is_blurry),
                    record.similar_cluster,
                    record.story_id,
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
                        person_id, embedding, embedding_dim, embedding_model,
                        left_eye_state, right_eye_state, left_eye_open_probability,
                        right_eye_open_probability, both_eyes_open, expression,
                        expression_confidence, smile_probability, expression_scores_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        face.eyes.left if face.eyes else None,
                        face.eyes.right if face.eyes else None,
                        face.eyes.left_open_probability if face.eyes else None,
                        face.eyes.right_open_probability if face.eyes else None,
                        (
                            int(face.eyes.both_open)
                            if face.eyes is not None and face.eyes.both_open is not None
                            else None
                        ),
                        face.expression.label if face.expression else None,
                        face.expression.confidence if face.expression else None,
                        face.expression.smile_probability if face.expression else None,
                        _json(face.expression.scores) if face.expression else None,
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
        photo_image_ids = {
            record.photo_id: image_ids[record.path] for record in records
        }
        _store_stories(connection, run_id, stories or [], photo_image_ids)
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


def _store_stories(
    connection: sqlite3.Connection,
    run_id: str,
    stories: list[StoryRecord],
    photo_image_ids: dict[str, int],
) -> None:
    connection.execute("DELETE FROM stories WHERE run_id = ?", (run_id,))
    for story in stories:
        connection.execute(
            """
            INSERT INTO stories (
                run_id, story_id, title, started_at, ended_at,
                representative_image_id, scene_tags_json, object_tags_json,
                naming_model, algorithm_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                run_id,
                story.story_id,
                story.title,
                story.started_at,
                story.ended_at,
                photo_image_ids.get(story.representative_photo_id),
                _json(story.scene_labels),
                _json(story.object_labels),
                story.naming_model,
                STORY_ALGORITHM_VERSION,
            ),
        )


def _ensure_stories(connection: sqlite3.Connection, run_id: str) -> None:
    counts = connection.execute(
        """
        SELECT COUNT(*) AS photos,
               SUM(CASE WHEN story_id IS NOT NULL THEN 1 ELSE 0 END) AS assigned
        FROM photo_analysis
        WHERE run_id = ?
        """,
        (run_id,),
    ).fetchone()
    story_state = connection.execute(
        """
        SELECT COUNT(*) AS stories,
               MIN(COALESCE(algorithm_version, 1)) AS algorithm_version
        FROM stories WHERE run_id = ?
        """,
        (run_id,),
    ).fetchone()
    story_count = int(story_state["stories"] or 0)
    if int(counts["photos"] or 0) == 0:
        return
    if (
        story_count > 0
        and int(counts["assigned"] or 0) == int(counts["photos"])
        and int(story_state["algorithm_version"] or 1) >= STORY_ALGORITHM_VERSION
    ):
        return

    rows = connection.execute(
        """
        SELECT pa.photo_id, pa.image_id, pa.quality, pa.is_blurry,
               pa.scene_tags_json, pa.object_tags_json,
               pa.vision_embedding, pa.vision_embedding_dim,
               i.taken_at, i.modified_at, i.file_name,
               i.gps_latitude, i.gps_longitude, i.path
        FROM photo_analysis AS pa
        JOIN images AS i ON i.id = pa.image_id
        WHERE pa.run_id = ? AND i.availability = 'present'
        ORDER BY COALESCE(i.taken_at, i.modified_at), i.path
        """,
        (run_id,),
    ).fetchall()
    people_by_image: defaultdict[int, set[str]] = defaultdict(set)
    for face in connection.execute(
        """
        SELECT image_id, person_id, person_cluster
        FROM faces
        WHERE run_id = ?
        """,
        (run_id,),
    ):
        identity = (
            f"person:{face['person_id']}"
            if face["person_id"] is not None
            else f"cluster:{face['person_cluster']}"
        )
        if face["person_id"] is not None or face["person_cluster"] is not None:
            people_by_image[int(face["image_id"])].add(identity)

    config_row = connection.execute(
        "SELECT config_json FROM analysis_runs WHERE id = ?", (run_id,)
    ).fetchone()
    config = json.loads(config_row["config_json"]) if config_row else {}
    story_photos = [
        StoryPhoto(
            photo_id=str(row["photo_id"]),
            taken_at=(
                row["taken_at"]
                or _filename_taken_at(str(row["file_name"]))
                or row["modified_at"]
            ),
            gps_latitude=row["gps_latitude"],
            gps_longitude=row["gps_longitude"],
            people=frozenset(people_by_image[int(row["image_id"])]),
            scenes=_tag_pairs(row["scene_tags_json"]),
            objects=_tag_pairs(row["object_tags_json"]),
            embedding=(
                tuple(
                    _decode_embedding(
                        row["vision_embedding"], int(row["vision_embedding_dim"])
                    ).tolist()
                )
                if row["vision_embedding"] is not None
                and row["vision_embedding_dim"] is not None
                else None
            ),
            quality=float(row["quality"] or 0),
            is_blurry=bool(row["is_blurry"]),
        )
        for row in rows
    ]
    stories = detect_stories(
        story_photos,
        gap_minutes=int(config.get("story_gap_minutes", 120)),
        continuity_minutes=int(config.get("story_continuity_minutes", 360)),
        max_duration_hours=int(config.get("story_max_duration_hours", 12)),
        semantic_break_minutes=int(config.get("story_semantic_break_minutes", 30)),
    )
    story_namer = StoryNamer(
        backend=str(config.get("story_naming_backend", "auto")),
        base_url=str(config.get("lmstudio_url", "http://127.0.0.1:1234/v1")),
        model=str(config.get("lmstudio_model", "qwen/qwen3-vl-2b")),
        max_images=int(config.get("story_vlm_images", 4)),
        timeout=float(config.get("story_vlm_timeout", 90.0)),
    )
    stories = story_namer.refine(
        stories,
        {str(row["photo_id"]): str(row["path"]) for row in rows},
    )
    for story in stories:
        connection.executemany(
            "UPDATE photo_analysis SET story_id = ? WHERE run_id = ? AND photo_id = ?",
            [(story.story_id, run_id, photo_id) for photo_id in story.photo_ids],
        )
    _store_stories(
        connection,
        run_id,
        stories,
        {str(row["photo_id"]): int(row["image_id"]) for row in rows},
    )


def _tag_pairs(value: str | None) -> tuple[tuple[str, float], ...]:
    result: list[tuple[str, float]] = []
    for item in json.loads(value or "[]"):
        if isinstance(item, dict) and item.get("label"):
            result.append((str(item["label"]), float(item.get("confidence", 0))))
        elif isinstance(item, str):
            result.append((item, 1.0))
    return tuple(result)


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
                   SUM(CASE WHEN availability = 'present' THEN 1 ELSE 0 END) AS available,
                   COUNT(DISTINCT sha256) AS unique_files,
                   SUM(file_size_bytes) AS bytes,
                   SUM(CASE WHEN gps_latitude IS NOT NULL THEN 1 ELSE 0 END) AS with_gps,
                   SUM(CASE WHEN taken_at IS NOT NULL THEN 1 ELSE 0 END) AS with_taken_at
            FROM images
            """
        ).fetchone()
        states = {
            row[0]: int(row[1])
            for row in connection.execute(
                "SELECT availability, COUNT(*) FROM images GROUP BY availability"
            )
        }
        runs = connection.execute("SELECT COUNT(*) FROM analysis_runs").fetchone()[0]
        faces = connection.execute("SELECT COUNT(*) FROM faces").fetchone()[0]
        linked_faces = connection.execute(
            "SELECT COUNT(*) FROM faces WHERE person_id IS NOT NULL"
        ).fetchone()[0]
        people = connection.execute("SELECT COUNT(*) FROM people").fetchone()[0]
        stories = connection.execute("SELECT COUNT(*) FROM stories").fetchone()[0]
    count_fields = ("images", "available", "unique_files", "bytes", "with_gps", "with_taken_at")
    result = {key: int(image_counts[key] or 0) for key in count_fields}
    result.update(
        {
            "availability": {
                key: states.get(key, 0) for key in ("present", "missing", "archived")
            },
            "analysis_runs": int(runs),
            "faces": int(faces),
            "linked_faces": int(linked_faces),
            "people": int(people),
            "stories": int(stories),
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
                   gps_latitude, gps_longitude, file_size_bytes, availability
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
            _analysis_result(item)
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
            _face_result(item)
            for item in connection.execute(
                """
                SELECT f.id, f.run_id, f.image_id, f.face_id, f.face_index,
                       f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                       f.confidence, f.person_cluster, f.person_id,
                       f.embedding_dim, f.embedding_model, f.left_eye_state,
                       f.right_eye_state, f.left_eye_open_probability,
                       f.right_eye_open_probability, f.both_eyes_open,
                       f.expression, f.expression_confidence,
                       f.smile_probability, f.expression_scores_json,
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
            _face_result(item)
            for item in connection.execute(
                """
                SELECT f.id, f.run_id, f.face_id, f.face_index, f.image_id,
                       f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                       f.confidence, f.person_cluster, f.embedding_model,
                       f.left_eye_state, f.right_eye_state,
                       f.left_eye_open_probability, f.right_eye_open_probability,
                       f.both_eyes_open, f.expression, f.expression_confidence,
                       f.smile_probability, f.expression_scores_json,
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
        target = connection.execute(
            "SELECT id, name, embedding_model FROM people WHERE id = ?", (target_id,)
        ).fetchone()
        if target is None:
            raise ValueError(f"Person id does not exist: {target_id}")
        placeholders = ", ".join("?" for _ in sources)
        rows = connection.execute(
            f"SELECT id, name, embedding_model FROM people WHERE id IN ({placeholders}) ORDER BY id",
            sources,
        ).fetchall()
        found = {int(row["id"]) for row in rows}
        missing = sorted(set(sources) - found)
        if missing:
            raise ValueError(f"Person ids do not exist: {missing}")
        if any(row["embedding_model"] != target["embedding_model"] for row in rows):
            raise ValueError("Нельзя объединить людей из разных моделей признаков")
        inherited_name = next((row["name"] for row in rows if row["name"]), None)
        if not target["name"] and inherited_name:
            connection.execute(
                "UPDATE people SET name = ?, updated_at = ? WHERE id = ?",
                (inherited_name, utc_now(), target_id),
            )
        connection.execute(
            f"UPDATE faces SET person_id = ? WHERE person_id IN ({placeholders})",
            [target_id, *sources],
        )
        connection.execute(f"DELETE FROM people WHERE id IN ({placeholders})", sources)
        _refresh_person_centroid(connection, target_id)
    return get_person(database, target_id)


def get_desktop_people(database: Path) -> dict[str, Any]:
    """Return people summaries for the desktop face-assignment editor."""
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        people = [
            dict(row)
            for row in connection.execute(
                """
                SELECT p.id, p.public_id, p.name, p.embedding_model,
                       COUNT(f.id) AS face_count,
                       COUNT(DISTINCT f.image_id) AS photo_count,
                       MIN(f.id) AS cover_face_id
                FROM people AS p
                LEFT JOIN faces AS f ON f.person_id = p.id
                GROUP BY p.id
                ORDER BY (COUNT(f.id) = 0), photo_count DESC, face_count DESC, p.id
                """
            ).fetchall()
        ]
        unassigned_count = int(
            connection.execute(
                "SELECT COUNT(*) FROM faces WHERE person_id IS NULL"
            ).fetchone()[0]
        )
        total_faces = int(connection.execute("SELECT COUNT(*) FROM faces").fetchone()[0])
    return {
        "database": str(database.resolve()),
        "people": people,
        "unassigned_count": unassigned_count,
        "total_faces": total_faces,
    }


def get_desktop_faces(database: Path, person_id: int | None) -> dict[str, Any]:
    """Return face observations belonging to one person, or currently unassigned."""
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        if person_id is not None:
            person = connection.execute(
                "SELECT id, public_id, name, embedding_model FROM people WHERE id = ?",
                (person_id,),
            ).fetchone()
            if person is None:
                raise ValueError(f"Person id does not exist: {person_id}")
            owner: dict[str, Any] | None = dict(person)
            predicate = "f.person_id = ?"
            parameters: tuple[object, ...] = (person_id,)
        else:
            owner = None
            predicate = "f.person_id IS NULL"
            parameters = ()
        faces = [
            _face_result(row)
            for row in connection.execute(
                f"""
                SELECT f.id, f.run_id, f.face_id, f.face_index, f.image_id,
                       f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                       f.confidence, f.person_id, f.embedding_model,
                       f.left_eye_state, f.right_eye_state, f.both_eyes_open,
                       f.expression, f.expression_confidence, f.smile_probability,
                       f.expression_scores_json, i.path, i.file_name, i.taken_at,
                       i.orientation
                FROM faces AS f
                JOIN images AS i ON i.id = f.image_id
                WHERE {predicate}
                ORDER BY COALESCE(i.taken_at, i.modified_at) DESC, i.path, f.face_index
                """,
                parameters,
            ).fetchall()
        ]
    return {"person": owner, "faces": faces}


def set_face_person(database: Path, face_id: int, person_id: int | None) -> dict[str, Any]:
    """Manually assign one face observation to a person, or detach it."""
    with connect(database) as connection:
        face = connection.execute(
            "SELECT id, person_id, embedding_model FROM faces WHERE id = ?", (face_id,)
        ).fetchone()
        if face is None:
            raise ValueError(f"Face id does not exist: {face_id}")
        old_person_id = int(face["person_id"]) if face["person_id"] is not None else None
        if person_id is not None:
            person = connection.execute(
                "SELECT id, embedding_model FROM people WHERE id = ?", (person_id,)
            ).fetchone()
            if person is None:
                raise ValueError(f"Person id does not exist: {person_id}")
            if face["embedding_model"] != person["embedding_model"]:
                raise ValueError("Нельзя связать лицо и человека из разных моделей признаков")
        connection.execute("UPDATE faces SET person_id = ? WHERE id = ?", (person_id, face_id))
        for affected_id in {old_person_id, person_id} - {None}:
            _refresh_person_centroid(connection, int(affected_id))
    return {"face_id": face_id, "person_id": person_id}


def create_person_from_face(
    database: Path, face_id: int, name: str | None = None
) -> dict[str, Any]:
    """Create a manual person identity using one face as its initial centroid."""
    normalized = name.strip() if name else None
    with connect(database) as connection:
        face = connection.execute(
            """
            SELECT id, person_id, embedding, embedding_dim, embedding_model
            FROM faces WHERE id = ?
            """,
            (face_id,),
        ).fetchone()
        if face is None:
            raise ValueError(f"Face id does not exist: {face_id}")
        if face["embedding"] is None or face["embedding_dim"] is None or not face["embedding_model"]:
            raise ValueError("У лица нет признаков, необходимых для создания человека")
        old_person_id = int(face["person_id"]) if face["person_id"] is not None else None
        now = utc_now()
        cursor = connection.execute(
            """
            INSERT INTO people (
                public_id, name, embedding_model, centroid_embedding,
                embedding_dim, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                str(uuid.uuid4()),
                normalized or None,
                face["embedding_model"],
                face["embedding"],
                face["embedding_dim"],
                now,
                now,
            ),
        )
        person_id = int(cursor.lastrowid)
        connection.execute("UPDATE faces SET person_id = ? WHERE id = ?", (person_id, face_id))
        if old_person_id is not None:
            _refresh_person_centroid(connection, old_person_id)
    return get_person(database, person_id)


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
            "availability": "present",
        }
    )
    columns = list(values)
    parameters = list(values.values())
    placeholders = ", ".join("?" for _ in columns)
    existing = connection.execute("SELECT id FROM images WHERE path = ?", (item.path,)).fetchone()
    if existing is None:
        moved = connection.execute(
            "SELECT id FROM images WHERE sha256 = ? AND availability IN ('missing', 'archived')",
            (item.sha256,),
        ).fetchall()
        if len(moved) == 1:
            assignments = ", ".join(f"{column} = ?" for column in columns)
            connection.execute(
                f"UPDATE images SET {assignments} WHERE id = ?", [*parameters, moved[0]["id"]]
            )
            return int(moved[0]["id"])
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


def _face_result(row: sqlite3.Row) -> dict[str, Any]:
    result = dict(row)
    scores = result.pop("expression_scores_json", None)
    result["expression_scores"] = json.loads(scores) if scores else None
    if result.get("both_eyes_open") is not None:
        result["both_eyes_open"] = bool(result["both_eyes_open"])
    return result


def _migrate_schema(connection: sqlite3.Connection) -> None:
    columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(faces)")}
    additions = {
        "left_eye_state": "TEXT",
        "right_eye_state": "TEXT",
        "left_eye_open_probability": "REAL",
        "right_eye_open_probability": "REAL",
        "both_eyes_open": "INTEGER",
        "expression": "TEXT",
        "expression_confidence": "REAL",
        "smile_probability": "REAL",
        "expression_scores_json": "TEXT",
    }
    for name, sql_type in additions.items():
        if name not in columns:
            connection.execute(f"ALTER TABLE faces ADD COLUMN {name} {sql_type}")
    analysis_columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(photo_analysis)")
    }
    analysis_additions = {
        "aesthetic_score": "REAL",
        "composition_score": "REAL",
        "rule_of_thirds": "REAL",
        "frame_occupancy": "REAL",
        "negative_space": "REAL",
        "crop_risk": "REAL",
        "color_balance": "REAL",
        "color_harmony": "REAL",
        "main_subject_json": "TEXT",
        "scene_tags_json": "TEXT NOT NULL DEFAULT '[]'",
        "object_tags_json": "TEXT NOT NULL DEFAULT '[]'",
        "story_id": "INTEGER",
        "vision_embedding": "BLOB",
        "vision_embedding_dim": "INTEGER",
        "vision_embedding_model": "TEXT",
    }
    for name, sql_type in analysis_additions.items():
        if name not in analysis_columns:
            connection.execute(f"ALTER TABLE photo_analysis ADD COLUMN {name} {sql_type}")
    if "clip_embedding" in analysis_columns:
        connection.execute(
            """
            UPDATE photo_analysis
            SET vision_embedding = COALESCE(vision_embedding, clip_embedding),
                vision_embedding_dim = COALESCE(
                    vision_embedding_dim, clip_embedding_dim
                ),
                vision_embedding_model = COALESCE(
                    vision_embedding_model, clip_embedding_model
                )
            WHERE clip_embedding IS NOT NULL
            """
        )
    connection.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_photo_analysis_story
        ON photo_analysis(run_id, story_id)
        """
    )
    story_columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(stories)")
    }
    story_additions = {
        "naming_model": "TEXT",
        "algorithm_version": "INTEGER NOT NULL DEFAULT 1",
    }
    for name, sql_type in story_additions.items():
        if name not in story_columns:
            connection.execute(f"ALTER TABLE stories ADD COLUMN {name} {sql_type}")
    settings_columns = {
        str(row[1]) for row in connection.execute("PRAGMA table_info(desktop_run_settings)")
    }
    if settings_columns and "selection_initialized" not in settings_columns:
        connection.execute(
            """
            ALTER TABLE desktop_run_settings
            ADD COLUMN selection_initialized INTEGER NOT NULL DEFAULT 0
            """
        )
        connection.execute(
            "UPDATE desktop_run_settings SET selection_initialized = 1"
        )


def _analysis_result(row: sqlite3.Row) -> dict[str, Any]:
    result = dict(row)
    result["main_subject"] = _json_or_none(result.pop("main_subject_json", None))
    result["scene_tags"] = json.loads(result.pop("scene_tags_json", "[]"))
    result["object_tags"] = json.loads(result.pop("object_tags_json", "[]"))
    return result


def _json_or_none(value: str | None) -> Any:
    return json.loads(value) if value else None


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
