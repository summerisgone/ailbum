from __future__ import annotations

from collections.abc import Iterable
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
from PIL import ExifTags, Image, ImageOps

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"}


def discover_images(root: Path, recursive: bool = True) -> list[Path]:
    if root.is_file():
        return [root] if root.suffix.lower() in IMAGE_SUFFIXES else []
    pattern = "**/*" if recursive else "*"
    return sorted(
        path for path in root.glob(pattern) if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )


def load_image(path: Path) -> np.ndarray:
    """Load an image as orientation-corrected BGR without non-ASCII path issues."""
    with Image.open(path) as source:
        rgb = ImageOps.exif_transpose(source).convert("RGB")
        return cv2.cvtColor(np.asarray(rgb), cv2.COLOR_RGB2BGR)


def read_taken_at(path: Path) -> datetime | None:
    try:
        with Image.open(path) as image:
            exif = image.getexif()
            tags = {ExifTags.TAGS.get(key, key): value for key, value in exif.items()}
            value = tags.get("DateTimeOriginal") or tags.get("DateTime")
            if value:
                # EXIF normally stores local wall time without a UTC offset.
                return datetime.strptime(str(value), "%Y:%m:%d %H:%M:%S")  # noqa: DTZ007
    except (OSError, ValueError, TypeError):
        pass
    try:
        return datetime.fromtimestamp(path.stat().st_mtime).astimezone()
    except OSError:
        return None


def relative_paths(paths: Iterable[Path], root: Path) -> dict[Path, str]:
    base = root if root.is_dir() else root.parent
    result: dict[Path, str] = {}
    for path in paths:
        try:
            result[path] = str(path.relative_to(base))
        except ValueError:
            result[path] = str(path)
    return result
