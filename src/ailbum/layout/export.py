from __future__ import annotations

import shutil
from pathlib import Path

from ailbum.database import connect

EXPORT_DIR = "Раскладка альбома"


def export_originals(database: Path, run_id: str, folder: Path) -> dict:
    """Copy the original files of placed photos, named so they sort in album order."""
    with connect(database) as connection:
        layout = connection.execute("SELECT id FROM layouts WHERE run_id = ?", (run_id,)).fetchone()
        if layout is None:
            raise ValueError("Раскладка не создана")
        rows = connection.execute(
            "SELECT s.position, p.cell_index, i.path, i.file_name FROM layout_placements p"
            " JOIN layout_spreads s ON s.id = p.spread_id JOIN images i ON i.id = p.image_id"
            " WHERE s.layout_id = ? ORDER BY s.position, p.cell_index",
            (layout["id"],),
        ).fetchall()
    target = _unique(Path(folder) / EXPORT_DIR)
    target.mkdir(parents=True)
    copied, missing = 0, []
    for row in rows:
        source = Path(row["path"])
        name = f"{row['position']:02d}-{row['cell_index'] + 1}_{row['file_name']}"
        try:
            shutil.copy2(source, target / name)
        except OSError:
            missing.append(str(source))
            continue
        copied += 1
    return {"folder": str(target), "count": copied, "missing": missing}


def _unique(path: Path) -> Path:
    candidate, number = path, 2
    while candidate.exists():
        candidate = path.with_name(f"{path.name} {number}")
        number += 1
    return candidate
