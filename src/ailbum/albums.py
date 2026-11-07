import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import PurePath

STATUS_ORDER = {"draft": 0, "ordered": 1, "archived": 2}
TRANSITIONS = {("draft", "ordered"), ("ordered", "draft"), ("ordered", "archived")}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def get_album(connection: sqlite3.Connection, album_id: int) -> dict:
    row = connection.execute(
        """
        SELECT a.*, (SELECT COUNT(*) FROM album_photos WHERE album_id = a.id) AS photo_count
        FROM albums AS a WHERE a.id = ?
        """,
        (album_id,),
    ).fetchone()
    if row is None:
        raise ValueError("Альбом не найден")
    sources = [
        str(r[0])
        for r in connection.execute(
            "SELECT source_root FROM album_sources WHERE album_id = ? ORDER BY source_root",
            (album_id,),
        )
    ]
    return {
        "id": row["id"],
        "public_id": row["public_id"],
        "title": row["title"],
        "purpose": row["purpose"],
        "status": row["status"],
        "target_count": row["target_count"],
        "run_id": row["run_id"],
        "sources": sources,
        "photo_count": row["photo_count"],
        "ordered_at": row["ordered_at"],
        "archived_at": row["archived_at"],
        "updated_at": row["updated_at"],
    }


def create_album(
    connection: sqlite3.Connection,
    title: str,
    sources: list[str],
    run_id: str | None = None,
    target_count: int = 24,
) -> int:
    now = _now()
    cursor = connection.execute(
        """
        INSERT INTO albums (public_id, title, target_count, run_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (str(uuid.uuid4()), title, target_count, run_id, now, now),
    )
    album_id = int(cursor.lastrowid)
    connection.executemany(
        "INSERT INTO album_sources (album_id, source_root) VALUES (?, ?)",
        [(album_id, source) for source in sorted({str(s) for s in sources})],
    )
    return album_id


def list_albums(connection: sqlite3.Connection) -> list[dict]:
    ids = [r[0] for r in connection.execute("SELECT id FROM albums ORDER BY updated_at DESC, id DESC")]
    albums = [get_album(connection, i) for i in ids]
    albums.sort(key=lambda a: STATUS_ORDER[a["status"]])  # stable: keeps updated_at DESC
    return albums


def set_status(connection: sqlite3.Connection, album_id: int, status: str) -> dict:
    album = get_album(connection, album_id)
    current = album["status"]
    if current == status:
        return album
    if (current, status) not in TRANSITIONS:
        raise ValueError(f"Переход {current} -> {status} недоступен")
    now = _now()
    if status == "ordered":
        extra, values = ", ordered_at = ?", (now,)
    elif status == "draft":
        extra, values = ", ordered_at = NULL", ()
    else:
        extra, values = ", archived_at = ?", (now,)
    connection.execute(
        f"UPDATE albums SET status = ?, updated_at = ?{extra} WHERE id = ?",
        (status, now, *values, album_id),
    )
    return get_album(connection, album_id)


def rename_album(connection: sqlite3.Connection, album_id: int, title: str) -> dict:
    title = title.strip()
    if not title or len(title) > 200:
        raise ValueError("Название должно быть от 1 до 200 символов")
    get_album(connection, album_id)
    connection.execute(
        "UPDATE albums SET title = ?, updated_at = ? WHERE id = ?", (title, _now(), album_id)
    )
    return get_album(connection, album_id)


def delete_album(
    connection: sqlite3.Connection, album_id: int, forget_decisions: bool = False
) -> None:
    album = get_album(connection, album_id)
    if album["status"] != "draft" and not forget_decisions:
        raise ValueError("Архивный альбом удаляется только с forget_decisions")
    connection.execute("DELETE FROM albums WHERE id = ?", (album_id,))


def attach_run(connection: sqlite3.Connection, run_id: str, sources: list[str]) -> int:
    normalized = sorted({str(s) for s in sources})
    for row in connection.execute(
        "SELECT id FROM albums WHERE status = 'draft' ORDER BY updated_at DESC, id DESC"
    ).fetchall():
        album_id = int(row[0])
        existing = [
            r[0]
            for r in connection.execute(
                "SELECT source_root FROM album_sources WHERE album_id = ? ORDER BY source_root",
                (album_id,),
            )
        ]
        if existing == normalized:
            connection.execute(
                "UPDATE albums SET run_id = ?, updated_at = ? WHERE id = ?",
                (run_id, _now(), album_id),
            )
            return album_id
    title = PurePath(normalized[0]).name if normalized else "Альбом"
    return create_album(connection, title or normalized[0], normalized, run_id)


def require_draft(connection: sqlite3.Connection, album_id: int) -> None:
    if get_album(connection, album_id)["status"] != "draft":
        raise ValueError("Альбом заказан: изменения недоступны")
