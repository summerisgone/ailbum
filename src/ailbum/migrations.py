from __future__ import annotations

import re
import sqlite3
import uuid
from pathlib import PurePath

_REBUILT = ("images", "photo_analysis", "faces", "layouts", "layout_placements")


def migrate_v12(connection: sqlite3.Connection) -> None:
    """Migrate a v11 database (images.missing) to the v12 album shape."""
    from ailbum.database import SCHEMA, utc_now

    ddl = {
        match.group(1): match.group(0)
        for match in re.finditer(
            r"CREATE TABLE IF NOT EXISTS (\w+) \(.*?\n\);", SCHEMA, re.DOTALL
        )
    }
    connection.commit()
    connection.execute("PRAGMA foreign_keys = OFF")
    try:
        connection.execute("BEGIN")
        now = utc_now()
        _create_albums(connection, now)
        for table in _REBUILT:
            _rebuild(connection, table, ddl[table])
        connection.execute("DROP TABLE IF EXISTS photo_selections")
        connection.execute("DROP TABLE IF EXISTS desktop_run_settings")
        if connection.execute("PRAGMA foreign_key_check").fetchall():
            raise sqlite3.IntegrityError("foreign_key_check failed after v12 migration")
        connection.execute("COMMIT")
    except BaseException:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.execute("PRAGMA foreign_keys = ON")
    connection.executescript(SCHEMA)  # recreate indexes dropped with rebuilt tables


def _tables(connection: sqlite3.Connection) -> set[str]:
    return {
        row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }


def _columns(connection: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]


def _rebuild(connection: sqlite3.Connection, table: str, create_sql: str) -> None:
    new = f"{table}_new"
    connection.execute(f"DROP TABLE IF EXISTS {new}")
    connection.execute(create_sql.replace(
        f"CREATE TABLE IF NOT EXISTS {table} (", f"CREATE TABLE {new} (", 1
    ))
    old_columns = set(_columns(connection, table))
    new_columns = _columns(connection, new)
    select: dict[str, str] = {}
    for column in new_columns:
        if column in old_columns:
            select[column] = column
    if table == "images":
        select["availability"] = "CASE WHEN missing = 1 THEN 'missing' ELSE 'present' END"
    if table == "layouts":
        select["album_id"] = "(SELECT a.id FROM albums AS a WHERE a.run_id = layouts.run_id)"
    connection.execute(
        f"INSERT INTO {new} ({', '.join(select)}) "
        f"SELECT {', '.join(select.values())} FROM {table}"
    )
    connection.execute(f"DROP TABLE {table}")
    connection.execute(f"ALTER TABLE {new} RENAME TO {table}")


def _create_albums(connection: sqlite3.Connection, now: str) -> None:
    present = _tables(connection)
    has_selections = "photo_selections" in present
    has_settings = "desktop_run_settings" in present
    parts = ["SELECT run_id FROM layouts"] if "layouts" in present else []
    if has_selections:
        parts.append("SELECT run_id FROM photo_selections")
    if has_settings:
        parts.append("SELECT run_id FROM desktop_run_settings")
    if not parts:
        return
    runs = connection.execute(
        f"""
        SELECT r.id, r.source FROM analysis_runs AS r
        WHERE r.id IN ({' UNION '.join(parts)})
        ORDER BY r.started_at, r.id
        """
    ).fetchall()
    for run_id, source in runs:
        target = 24
        if has_settings:
            row = connection.execute(
                "SELECT target_count FROM desktop_run_settings WHERE run_id = ?", (run_id,)
            ).fetchone()
            if row is not None:
                target = int(row[0])
        title = PurePath(source).name or source
        album_id = connection.execute(
            """
            INSERT INTO albums (public_id, title, target_count, run_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (str(uuid.uuid4()), title, target, run_id, now, now),
        ).lastrowid
        connection.execute(
            "INSERT INTO album_sources (album_id, source_root) VALUES (?, ?)", (album_id, source)
        )
        if not has_selections:
            continue
        connection.execute(
            """
            INSERT INTO album_photos (album_id, image_id, position, added_at)
            SELECT ?, image_id, position, selected_at FROM photo_selections WHERE run_id = ?
            """,
            (album_id, run_id),
        )
        final = {
            row[0]
            for row in connection.execute(
                "SELECT image_id FROM photo_selections WHERE run_id = ?", (run_id,)
            )
        }
        if not final:
            continue
        auto = {
            row[0]
            for row in connection.execute(
                "SELECT image_id FROM photo_analysis WHERE run_id = ? AND selected = 1",
                (run_id,),
            )
        }
        events = [(i, "add") for i in sorted(final - auto)] + [
            (i, "remove") for i in sorted(auto - final)
        ]
        connection.executemany(
            """
            INSERT INTO selection_events (album_id, run_id, image_id, action, source, created_at)
            VALUES (?, ?, ?, ?, 'backfill', ?)
            """,
            [(album_id, run_id, image_id, action, now) for image_id, action in events],
        )
