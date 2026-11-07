from __future__ import annotations

import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

from ailbum.database import connect

EXPORT_DIR = "Раскладка альбома"


def export_originals(database: Path, album_id: int, folder: Path) -> dict:
    """Copy the original files of placed photos, named so they sort in album order."""
    with connect(database) as connection:
        layout = connection.execute("SELECT id, selection_hash FROM layouts WHERE album_id = ?", (album_id,)).fetchone()
        if layout is None:
            raise ValueError("Раскладка не создана")
        rows = connection.execute(
            "SELECT s.position, p.cell_index, i.path, i.file_name, i.availability FROM layout_placements p"
            " JOIN layout_spreads s ON s.id = p.spread_id JOIN images i ON i.id = p.image_id"
            " WHERE s.layout_id = ? ORDER BY s.position, p.cell_index",
            (layout["id"],),
        ).fetchall()
        selection_hash = _selection_hash(connection, album_id)
    target = _unique(Path(folder) / EXPORT_DIR)
    target.mkdir(parents=True)
    copied, missing = 0, []
    for row in rows:
        source = Path(row["path"])
        if row["availability"] != "present":
            missing.append(str(source))
            continue
        name = f"{row['position']:02d}-{row['cell_index'] + 1}_{row['file_name']}"
        try:
            shutil.copy2(source, target / name)
        except OSError:
            missing.append(str(source))
            continue
        copied += 1
    with connect(database) as connection:
        cursor = connection.execute(
            "INSERT INTO album_exports (album_id, layout_id, selection_hash, folder, count,"
            " missing_json, exported_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                album_id,
                layout["id"],
                selection_hash,
                str(target),
                copied,
                json.dumps(missing, ensure_ascii=False),
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        export_id = int(cursor.lastrowid)
    return {"folder": str(target), "count": copied, "missing": missing, "export_id": export_id}


def _selection_hash(connection, album_id: int) -> str:
    ids = sorted(
        int(r[0])
        for r in connection.execute("SELECT image_id FROM album_photos WHERE album_id = ?", (album_id,))
    )
    return hashlib.sha256(",".join(str(i) for i in ids).encode()).hexdigest()


def _unique(path: Path) -> Path:
    candidate, number = path, 2
    while candidate.exists():
        candidate = path.with_name(f"{path.name} {number}")
        number += 1
    return candidate
