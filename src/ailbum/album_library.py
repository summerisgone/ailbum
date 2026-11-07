from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path
from typing import Any

import numpy as np

from ailbum import albums
from ailbum import database as db_module
from ailbum.database import connect, utc_now
from ailbum.ranking.select import Candidate, select_for_target


def _count(connection: sqlite3.Connection, album_id: int) -> int:
    return int(
        connection.execute(
            "SELECT COUNT(*) FROM album_photos WHERE album_id = ?", (album_id,)
        ).fetchone()[0]
    )


def _touch(connection: sqlite3.Connection, album_id: int) -> None:
    connection.execute("UPDATE albums SET updated_at = ? WHERE id = ?", (utc_now(), album_id))


def _event(connection, album_id, run_id, image_id, action, source) -> None:
    connection.execute(
        """INSERT INTO selection_events (album_id, run_id, image_id, action, source, created_at)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (album_id, run_id, image_id, action, source, utc_now()),
    )


def _add(connection, album_id, run_id, image_id, action, source) -> None:
    position = connection.execute(
        "SELECT COALESCE(MAX(position), 0) + 1 FROM album_photos WHERE album_id = ?",
        (album_id,),
    ).fetchone()[0]
    connection.execute(
        "INSERT INTO album_photos (album_id, image_id, position, added_at) VALUES (?, ?, ?, ?)",
        (album_id, image_id, position, utc_now()),
    )
    _event(connection, album_id, run_id, image_id, action, source)


def set_photo(
    connection: sqlite3.Connection,
    album_id: int,
    image_id: int,
    selected: bool,
    source: str = "manual",
) -> dict[str, Any]:
    albums.require_draft(connection, album_id)
    album = albums.get_album(connection, album_id)
    run_id = album["run_id"]
    present = connection.execute(
        "SELECT 1 FROM album_photos WHERE album_id = ? AND image_id = ?", (album_id, image_id)
    ).fetchone() is not None
    if not present:
        in_run = run_id is not None and connection.execute(
            "SELECT 1 FROM photo_analysis WHERE run_id = ? AND image_id = ?", (run_id, image_id)
        ).fetchone() is not None
        if not in_run:
            raise ValueError(f"Image {image_id} does not belong to album {album_id}")
    changed = False
    if selected and not present:
        _add(connection, album_id, run_id, image_id, "add", source)
        changed = True
    elif not selected and present:
        connection.execute(
            "DELETE FROM album_photos WHERE album_id = ? AND image_id = ?", (album_id, image_id)
        )
        _event(connection, album_id, run_id, image_id, "remove", source)
        changed = True
    if changed:
        _touch(connection, album_id)
    return {
        "album_id": album_id,
        "image_id": image_id,
        "favorite": selected,
        "changed": changed,
        "selected_count": _count(connection, album_id),
    }


def selection_hash(connection: sqlite3.Connection, album_id: int) -> str:
    ids = sorted(
        int(r[0])
        for r in connection.execute(
            "SELECT image_id FROM album_photos WHERE album_id = ?", (album_id,)
        )
    )
    return hashlib.sha256(",".join(str(i) for i in ids).encode("ascii")).hexdigest()


def set_target(connection: sqlite3.Connection, album_id: int, target_count: int) -> dict[str, Any]:
    if not 1 <= target_count <= 999:
        raise ValueError("Selection target must be between 1 and 999")
    albums.require_draft(connection, album_id)
    connection.execute(
        "UPDATE albums SET target_count = ?, updated_at = ? WHERE id = ?",
        (target_count, utc_now(), album_id),
    )
    return {"album_id": album_id, "target_count": target_count}


def _candidates(connection: sqlite3.Connection, run_id: str) -> list[Candidate]:
    rows = connection.execute(
        """
        SELECT pa.image_id, pa.quality, pa.story_id, pa.similar_cluster,
               pa.vision_embedding, pa.vision_embedding_dim
        FROM photo_analysis AS pa JOIN images AS i ON i.id = pa.image_id
        WHERE pa.run_id = ? AND pa.is_blurry = 0 AND pa.error IS NULL
          AND i.availability = 'present'
        ORDER BY pa.image_id
        """,
        (run_id,),
    ).fetchall()
    scores: dict[int, float] = {}
    try:
        from ailbum.ranking import features, store

        model = store.active_model(connection, "pointwise")
        if model is not None:
            vectors = features.from_rows(connection, run_id)
            ids = [r["image_id"] for r in rows if r["image_id"] in vectors]
            if ids:
                values = model.score(np.stack([vectors[i] for i in ids]))
                scores = {i: float(v) for i, v in zip(ids, values)}
    except (ImportError, AttributeError):
        scores = {}
    result = []
    for r in rows:
        embedding = None
        if r["vision_embedding"] is not None and r["vision_embedding_dim"] is not None:
            embedding = np.frombuffer(
                r["vision_embedding"], dtype=np.float32, count=int(r["vision_embedding_dim"])
            ).copy()
        score = scores.get(r["image_id"], float(r["quality"] or 0))
        result.append(Candidate(r["image_id"], score, r["story_id"], r["similar_cluster"], embedding))
    return result


def _seed(connection: sqlite3.Connection, album: dict) -> None:
    chosen = select_for_target(
        _candidates(connection, album["run_id"]), album["target_count"], []
    )
    for image_id in chosen:
        _add(connection, album["id"], album["run_id"], image_id, "seed", "auto")
    if chosen:
        _touch(connection, album["id"])


def autofill(connection: sqlite3.Connection, album_id: int) -> dict[str, Any]:
    albums.require_draft(connection, album_id)
    album = albums.get_album(connection, album_id)
    added: list[int] = []
    if album["run_id"] is not None:
        keep = [
            int(r[0])
            for r in connection.execute(
                "SELECT image_id FROM album_photos WHERE album_id = ? ORDER BY position",
                (album_id,),
            )
        ]
        chosen = select_for_target(
            _candidates(connection, album["run_id"]), album["target_count"], keep
        )
        kept = set(keep)
        for image_id in chosen:
            if image_id not in kept:
                _add(connection, album_id, album["run_id"], image_id, "add", "auto")
                added.append(image_id)
        if added:
            _touch(connection, album_id)
    return {"album_id": album_id, "added": added, "selected_count": _count(connection, album_id)}


_NO_ANALYSIS = """
    SELECT i.id, i.path, i.file_name, i.width, i.height, i.orientation, i.taken_at,
           i.modified_at, i.availability, NULL AS quality, NULL AS sharpness,
           NULL AS exposure, NULL AS aesthetic_score,
           NULL AS composition_score, NULL AS rule_of_thirds,
           NULL AS frame_occupancy, NULL AS negative_space,
           NULL AS crop_risk, NULL AS color_balance,
           NULL AS color_harmony, NULL AS main_subject_json,
           '[]' AS scene_tags_json, '[]' AS object_tags_json,
           0 AS is_blurry, NULL AS similar_cluster, NULL AS story_id,
           NULL AS story_title, 0 AS auto_selected, 0 AS face_count, 0 AS people_count,
           0 AS closed_eyes_count, 0 AS smiling_faces_count,
           NULL AS people_names, {favorite} AS favorite, {position} AS selection_position
    FROM images AS i {join}
    WHERE {where}
    ORDER BY COALESCE(i.taken_at, i.modified_at), i.path
"""


def _photo(row: sqlite3.Row) -> dict[str, Any]:
    result = dict(row)
    for key in ("is_blurry", "auto_selected", "favorite"):
        result[key] = bool(result[key])
    names = result.pop("people_names", None)
    result["people_names"] = names.split(",") if names else []
    result["main_subject"] = db_module._json_or_none(result.pop("main_subject_json", None))
    result["scene_tags"] = json.loads(result.pop("scene_tags_json", "[]"))
    result["object_tags"] = json.loads(result.pop("object_tags_json", "[]"))
    return result


def _default_album_id(connection: sqlite3.Connection) -> int | None:
    row = connection.execute(
        """SELECT id FROM albums
           ORDER BY (status = 'draft') DESC, updated_at DESC, id DESC LIMIT 1"""
    ).fetchone()
    return int(row[0]) if row else None


def get_library(database: Path, album_id: int | None = None) -> dict[str, Any]:
    if not database.exists():
        raise FileNotFoundError(f"Database does not exist: {database}")
    with connect(database) as connection:
        if album_id is None:
            album_id = _default_album_id(connection)
        if album_id is None:
            rows = connection.execute(
                _NO_ANALYSIS.format(
                    favorite="0", position="NULL", join="", where="i.availability = 'present'"
                )
            ).fetchall()
            return {
                "database": str(database.resolve()),
                "album": None,
                "albums": [],
                "run": None,
                "target_count": 24,
                "selected_count": 0,
                "stories": [],
                "photos": [_photo(r) for r in rows],
            }
        album = albums.get_album(connection, album_id)
        run_id = album["run_id"]
        if (
            album["status"] == "draft"
            and run_id is not None
            and _count(connection, album_id) == 0
            and connection.execute(
                "SELECT 1 FROM selection_events WHERE album_id = ?", (album_id,)
            ).fetchone() is None
        ):
            _seed(connection, album)
        run_result = None
        story_rows: list[sqlite3.Row] = []
        rows: list[sqlite3.Row] = []
        member_join = (
            "JOIN album_photos AS ap ON ap.image_id = i.id AND ap.album_id = ?"
        )
        if run_id is not None:
            run = connection.execute(
                """SELECT id, source, started_at, completed_at, face_backend, summary_json
                   FROM analysis_runs WHERE id = ?""",
                (run_id,),
            ).fetchone()
        else:
            run = None
        if run is not None:
            db_module._ensure_stories(connection, run_id)
            rows = connection.execute(
                """
                WITH face_summary AS (
                    SELECT f.image_id,
                           COUNT(*) AS face_count,
                           COUNT(DISTINCT f.person_id) AS people_count,
                           SUM(CASE WHEN f.both_eyes_open = 0 THEN 1 ELSE 0 END)
                               AS closed_eyes_count,
                           SUM(CASE WHEN f.smile_probability >= 0.5 THEN 1 ELSE 0 END)
                               AS smiling_faces_count,
                           GROUP_CONCAT(DISTINCT NULLIF(TRIM(p.name), '')) AS people_names
                    FROM faces AS f
                    LEFT JOIN people AS p ON p.id = f.person_id
                    WHERE f.run_id = ?
                    GROUP BY f.image_id
                )
                SELECT i.id, i.path, i.file_name, i.width, i.height, i.orientation,
                       i.taken_at, i.modified_at, i.availability,
                       pa.quality, pa.sharpness, pa.exposure,
                       pa.aesthetic_score, pa.composition_score, pa.rule_of_thirds,
                       pa.frame_occupancy, pa.negative_space, pa.crop_risk,
                       pa.color_balance, pa.color_harmony, pa.main_subject_json,
                       pa.scene_tags_json, pa.object_tags_json,
                       pa.is_blurry, pa.similar_cluster, pa.story_id,
                       s.title AS story_title,
                       pa.selected AS auto_selected,
                       COALESCE(fs.face_count, 0) AS face_count,
                       COALESCE(fs.people_count, 0) AS people_count,
                       COALESCE(fs.closed_eyes_count, 0) AS closed_eyes_count,
                       COALESCE(fs.smiling_faces_count, 0) AS smiling_faces_count,
                       fs.people_names,
                       CASE WHEN ap.image_id IS NULL THEN 0 ELSE 1 END AS favorite,
                       ap.position AS selection_position
                FROM photo_analysis AS pa
                JOIN images AS i ON i.id = pa.image_id
                LEFT JOIN stories AS s
                    ON s.run_id = pa.run_id AND s.story_id = pa.story_id
                LEFT JOIN face_summary AS fs ON fs.image_id = i.id
                LEFT JOIN album_photos AS ap
                    ON ap.album_id = ? AND ap.image_id = i.id
                WHERE pa.run_id = ?
                ORDER BY pa.story_id, COALESCE(i.taken_at, i.modified_at), i.path
                """,
                (run_id, album_id, run_id),
            ).fetchall()
            in_run = {r["id"] for r in rows}
            extra = connection.execute(
                _NO_ANALYSIS.format(
                    favorite="1", position="ap.position", join=member_join, where="1 = 1"
                ),
                (album_id,),
            ).fetchall()
            rows = rows + [r for r in extra if r["id"] not in in_run]
            story_rows = connection.execute(
                """
                SELECT s.story_id AS id, s.title, s.started_at, s.ended_at,
                       s.representative_image_id, s.naming_model,
                       COUNT(pa.image_id) AS photo_count
                FROM stories AS s
                LEFT JOIN photo_analysis AS pa
                    ON pa.run_id = s.run_id AND pa.story_id = s.story_id
                WHERE s.run_id = ?
                GROUP BY s.run_id, s.story_id
                ORDER BY s.story_id
                """,
                (run_id,),
            ).fetchall()
            run_result = dict(run)
            run_result["summary"] = json.loads(run_result.pop("summary_json"))
        else:
            rows = connection.execute(
                _NO_ANALYSIS.format(
                    favorite="1", position="ap.position", join=member_join, where="1 = 1"
                ),
                (album_id,),
            ).fetchall()
        photos = [_photo(r) for r in rows]
        return {
            "database": str(database.resolve()),
            "album": albums.get_album(connection, album_id),
            "albums": albums.list_albums(connection),
            "run": run_result,
            "target_count": album["target_count"],
            "selected_count": sum(1 for p in photos if p["favorite"]),
            "stories": [dict(r) for r in story_rows],
            "photos": photos,
        }
