from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

from ailbum.database import get_person


def compose_person_faces(
    database: Path,
    person_id: int,
    output: Path,
    *,
    face_size: int = 180,
    columns: int = 5,
) -> dict[str, object]:
    """Create a contact sheet from unique face observations of one person."""
    if face_size < 32:
        raise ValueError("Face size must be at least 32 pixels")
    if columns < 1:
        raise ValueError("Columns must be at least 1")

    person = get_person(database, person_id)
    unique_faces: list[dict[str, object]] = []
    seen: set[tuple[object, ...]] = set()
    for face in person["faces"]:
        key = (
            face["path"],
            face["bbox_x"],
            face["bbox_y"],
            face["bbox_width"],
            face["bbox_height"],
        )
        if key not in seen:
            seen.add(key)
            unique_faces.append(face)
    if not unique_faces:
        raise ValueError(f"Person {person_id} has no faces")

    gap = 8
    header_height = 42
    rows = math.ceil(len(unique_faces) / columns)
    width = columns * face_size + (columns + 1) * gap
    height = header_height + rows * face_size + (rows + 1) * gap
    sheet = Image.new("RGB", (width, height), (28, 30, 34))
    title = person["name"] or f"Person {person_id}"
    ImageDraw.Draw(sheet).text((gap, 12), f"{title} · {len(unique_faces)} faces", fill="white")

    for index, face in enumerate(unique_faces):
        tile = _face_tile(face, face_size)
        column = index % columns
        row = index // columns
        x = gap + column * (face_size + gap)
        y = header_height + gap + row * (face_size + gap)
        sheet.paste(tile, (x, y))

    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, quality=92)
    return {
        "person_id": person_id,
        "name": person["name"],
        "faces": len(unique_faces),
        "output": str(output.resolve()),
    }


def _face_tile(face: dict[str, object], size: int) -> Image.Image:
    path = Path(str(face["path"]))
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")
        x = int(face["bbox_x"])
        y = int(face["bbox_y"])
        width = int(face["bbox_width"])
        height = int(face["bbox_height"])
        margin = round(max(width, height) * 0.2)
        box = (
            max(0, x - margin),
            max(0, y - margin),
            min(image.width, x + width + margin),
            min(image.height, y + height + margin),
        )
        crop = image.crop(box)
        return ImageOps.fit(crop, (size, size), method=Image.Resampling.LANCZOS)
