from __future__ import annotations

import sqlite3
from pathlib import Path

from ailbum import albums
from ailbum.database import _refresh_person_centroid, connect


def _marks(ids: list[int]) -> str:
    return ", ".join("?" for _ in ids)


def _scope(
    connection: sqlite3.Connection, album_id: int | None, source: str | None
) -> list[int]:
    if (album_id is None) == (source is None):
        raise ValueError("Укажите ровно одно: альбом или источник")
    if album_id is not None:
        album = albums.get_album(connection, album_id)
        rows = connection.execute(
            """
            SELECT image_id FROM album_photos WHERE album_id = ?
            UNION
            SELECT image_id FROM photo_analysis WHERE run_id = ?
            """,
            (album_id, album["run_id"]),
        ).fetchall()
    else:
        rows = connection.execute(
            "SELECT id FROM images WHERE source_root = ?", (source,)
        ).fetchall()
    return sorted(int(row[0]) for row in rows)


def _build_plan(
    connection: sqlite3.Connection, database: Path, ids: list[int], album_id: int | None
) -> dict:
    plan: dict = {
        "images": len(ids), "faces": 0, "people_affected": [], "people_removed": [],
        "albums_affected": [], "layouts_placements": 0, "events": 0, "proxies": 0,
    }
    if not ids:
        return plan
    marks = _marks(ids)
    faces = connection.execute(
        f"SELECT id, person_id FROM faces WHERE image_id IN ({marks})", ids
    ).fetchall()
    face_ids = {row["id"] for row in faces}
    people = sorted({row["person_id"] for row in faces if row["person_id"] is not None})
    removed = []
    for person in people:
        remaining = connection.execute(
            "SELECT id FROM faces WHERE person_id = ?", (person,)
        ).fetchall()
        if all(row["id"] in face_ids for row in remaining):
            removed.append(person)
    affected = connection.execute(
        f"""
        SELECT DISTINCT a.id, a.title FROM albums AS a
        LEFT JOIN album_photos AS ap ON ap.album_id = a.id
        WHERE ap.image_id IN ({marks}) OR a.id = ?
        ORDER BY a.id
        """,
        [*ids, album_id],
    ).fetchall()
    plan.update(
        faces=len(face_ids),
        people_affected=people,
        people_removed=removed,
        albums_affected=[{"id": row["id"], "title": row["title"]} for row in affected],
        layouts_placements=connection.execute(
            f"SELECT COUNT(*) FROM layout_placements WHERE image_id IN ({marks})", ids
        ).fetchone()[0],
        events=connection.execute(
            f"SELECT COUNT(*) FROM selection_events WHERE image_id IN ({marks})", ids
        ).fetchone()[0],
    )
    plan["proxies"] = len(_proxy_files(connection, database, ids, sorted(face_ids)))
    return plan


def _proxy_files(
    connection: sqlite3.Connection, database: Path, ids: list[int], face_ids: list[int]
) -> list[Path]:
    root = database.parent / "proxies"
    marks = _marks(ids)
    shas = {
        row[0]
        for row in connection.execute(f"SELECT sha256 FROM images WHERE id IN ({marks})", ids)
    }
    files = []
    for sha in sorted(shas):
        shared = connection.execute(
            f"SELECT 1 FROM images WHERE sha256 = ? AND id NOT IN ({marks}) LIMIT 1",
            [sha, *ids],
        ).fetchone()
        if shared is None:
            files.append(root / "photos" / f"{sha}.jpg")
    files.extend(root / "faces" / f"{face_id}.jpg" for face_id in face_ids)
    return [path for path in files if path.exists()]


def plan_forget(database: Path, album_id: int | None, source: str | None) -> dict:
    with connect(database) as connection:
        ids = _scope(connection, album_id, source)
        return _build_plan(connection, database, ids, album_id)


def forget(database: Path, album_id: int | None, source: str | None) -> dict:
    with connect(database) as connection:
        ids = _scope(connection, album_id, source)
        plan = _build_plan(connection, database, ids, album_id)
        files: list[Path] = []
        if ids:
            marks = _marks(ids)
            faces = connection.execute(
                f"SELECT id, person_id FROM faces WHERE image_id IN ({marks})", ids
            ).fetchall()
            files = _proxy_files(connection, database, ids, [row["id"] for row in faces])
            people = {row["person_id"] for row in faces if row["person_id"] is not None}
            connection.execute(
                f"DELETE FROM layout_placements WHERE image_id IN ({marks})", ids
            )
            for table in ("selection_events", "album_photos", "faces", "photo_analysis",
                          "image_object_scans"):
                connection.execute(f"DELETE FROM {table} WHERE image_id IN ({marks})", ids)
            connection.execute(f"DELETE FROM images WHERE id IN ({marks})", ids)
            for person in sorted(people):
                left = connection.execute(
                    "SELECT 1 FROM faces WHERE person_id = ? LIMIT 1", (person,)
                ).fetchone()
                if left is None:
                    connection.execute("DELETE FROM people WHERE id = ?", (person,))
                else:
                    _refresh_person_centroid(connection, person)
        if album_id is not None:
            albums.delete_album(connection, album_id, forget_decisions=True)
    for path in files:
        path.unlink(missing_ok=True)
    return {**plan, "done": True}


def _tree_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def usage(database: Path) -> dict:
    with connect(database) as connection:
        counts = {
            row[0]: int(row[1])
            for row in connection.execute(
                "SELECT availability, COUNT(*) FROM images GROUP BY availability"
            )
        }
    database_bytes = sum(
        path.stat().st_size
        for path in (database, Path(f"{database}-wal"), Path(f"{database}-shm"))
        if path.exists()
    )
    return {
        "database_bytes": database_bytes,
        "proxies_bytes": _tree_bytes(database.parent / "proxies"),
        "feature_cache_bytes": _tree_bytes(database.parent / "feature-cache"),
        "images": {key: counts.get(key, 0) for key in ("present", "missing", "archived")},
    }
