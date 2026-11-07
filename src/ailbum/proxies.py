import os
import sqlite3
from collections.abc import Mapping
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps

PHOTO_SIDE = 1600
PHOTO_QUALITY = 82
FACE_SIZE = 240
FACE_QUALITY = 86


def _photo_proxy(database: Path, sha256: str) -> Path:
    return database.parent / "proxies" / "photos" / f"{sha256}.jpg"


def _face_proxy(database: Path, face_id: int) -> Path:
    return database.parent / "proxies" / "faces" / f"{face_id}.jpg"


def _select(database: Path, sql: str, params: tuple) -> list[sqlite3.Row]:
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    try:
        return connection.execute(sql, params).fetchall()
    finally:
        connection.close()


def _valid_jpeg(path: Path) -> bool:
    try:
        with Image.open(path) as image:
            image.load()
            return image.format == "JPEG"
    except (OSError, ValueError):
        return False


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_bytes(data)
    if not _valid_jpeg(temp):
        temp.unlink(missing_ok=True)
        raise ValueError(f"Proxy verification failed: {path.name}")
    os.replace(temp, path)


def _jpeg_bytes(image: Image.Image, quality: int) -> bytes:
    output = BytesIO()
    image.save(output, format="JPEG", quality=quality, optimize=True)
    return output.getvalue()


def _face_tile(image: Image.Image, face: Mapping, scale: float = 1.0) -> bytes:
    x = float(face["bbox_x"]) * scale
    y = float(face["bbox_y"]) * scale
    width = float(face["bbox_width"]) * scale
    height = float(face["bbox_height"]) * scale
    margin = round(max(width, height) * 0.2)
    crop = image.crop(
        (
            max(0, round(x) - margin),
            max(0, round(y) - margin),
            min(image.width, round(x + width) + margin),
            min(image.height, round(y + height) + margin),
        )
    )
    tile = ImageOps.fit(crop, (FACE_SIZE, FACE_SIZE), method=Image.Resampling.LANCZOS)
    return _jpeg_bytes(tile, FACE_QUALITY)


def build_proxies(database: Path, image_ids: list[int]) -> dict:
    built: list[int] = []
    failed: list[dict] = []
    for image_id in image_ids:
        try:
            rows = _select(
                database,
                "SELECT id, path, sha256, availability FROM images WHERE id = ?",
                (image_id,),
            )
            if not rows:
                raise ValueError("image not found")
            row = rows[0]
            target = _photo_proxy(database, str(row["sha256"]))
            source = Path(str(row["path"]))
            original = None
            if row["availability"] == "present" and source.is_file():
                original = Image.open(source)
            reuse = target.exists() and _valid_jpeg(target)
            try:
                if not reuse:
                    if original is None:
                        raise ValueError("original unavailable")
                    image = ImageOps.exif_transpose(original).convert("RGB")
                    image.thumbnail((PHOTO_SIDE, PHOTO_SIDE), Image.Resampling.LANCZOS)
                    _write_atomic(target, _jpeg_bytes(image, PHOTO_QUALITY))
                if original is not None:
                    full = ImageOps.exif_transpose(original).convert("RGB")
                    faces = _select(
                        database,
                        "SELECT id, bbox_x, bbox_y, bbox_width, bbox_height"
                        " FROM faces WHERE image_id = ?",
                        (image_id,),
                    )
                    for face in faces:
                        _write_atomic(_face_proxy(database, int(face["id"])), _face_tile(full, face))
            finally:
                if original is not None:
                    original.close()
            built.append(image_id)
        except Exception as error:  # noqa: BLE001
            failed.append({"image_id": image_id, "error": str(error)})
    return {"built": built, "failed": failed}


def image_source(database: Path, image: Mapping | sqlite3.Row) -> Path | None:
    if isinstance(image, sqlite3.Row):
        image = dict(image)
    if image.get("availability") == "present":
        path = Path(str(image["path"]))
        if path.is_file():
            return path
    proxy = _photo_proxy(database, str(image.get("sha256") or ""))
    return proxy if image.get("sha256") and proxy.is_file() else None


def face_thumbnail(database: Path, face_id: int) -> bytes:
    rows = _select(
        database,
        """
        SELECT f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height, i.path, i.sha256,
               i.availability, i.width, i.height, i.orientation
        FROM faces AS f JOIN images AS i ON i.id = f.image_id
        WHERE f.id = ?
        """,
        (face_id,),
    )
    if not rows:
        raise ValueError(f"Face id does not exist: {face_id}")
    face = rows[0]
    cached = _face_proxy(database, face_id)
    if cached.is_file() and _valid_jpeg(cached):
        return cached.read_bytes()
    path = Path(str(face["path"]))
    if face["availability"] == "present" and path.is_file():
        with Image.open(path) as source:
            return _face_tile(ImageOps.exif_transpose(source).convert("RGB"), face)
    proxy = _photo_proxy(database, str(face["sha256"]))
    if not proxy.is_file():
        raise ValueError(f"No image source for face {face_id}")
    width = int(face["width"] or 0)
    if int(face["orientation"] or 1) in (5, 6, 7, 8):
        width = int(face["height"] or 0)
    with Image.open(proxy) as source:
        image = source.convert("RGB")
    scale = image.width / width if width else 1.0
    return _face_tile(image, face, scale)
