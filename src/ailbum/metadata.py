from __future__ import annotations

import base64
import hashlib
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import ExifTags, Image
from PIL.TiffImagePlugin import IFDRational


@dataclass(slots=True)
class ImageMetadata:
    path: str
    source_root: str
    relative_path: str
    file_name: str
    extension: str
    file_size_bytes: int
    modified_at: str
    created_at: str | None
    sha256: str
    mime_type: str | None
    image_format: str | None
    color_mode: str | None
    width: int | None
    height: int | None
    frame_count: int | None
    orientation: int | None
    taken_at: str | None
    camera_make: str | None
    camera_model: str | None
    lens_model: str | None
    software: str | None
    gps_latitude: float | None
    gps_longitude: float | None
    gps_altitude: float | None
    exif: dict[str, Any]
    container_metadata: dict[str, Any]
    extraction_error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def collect_image_metadata(path: Path, source: Path) -> ImageMetadata:
    resolved = path.resolve()
    source_root = (source if source.is_dir() else source.parent).resolve()
    stat = resolved.stat()
    common: dict[str, Any] = {
        "path": str(resolved),
        "source_root": str(source_root),
        "relative_path": _relative_path(resolved, source_root),
        "file_name": resolved.name,
        "extension": resolved.suffix.lower(),
        "file_size_bytes": stat.st_size,
        "modified_at": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(),
        "created_at": _created_at(stat),
        "sha256": _sha256(resolved),
    }
    try:
        with Image.open(resolved) as image:
            exif = image.getexif()
            sections = _extract_exif_sections(exif)
            flattened = {**sections.get("ifd0", {}), **sections.get("exif", {})}
            gps = sections.get("gps", {})
            latitude, longitude, altitude = _gps_coordinates(gps)
            return ImageMetadata(
                **common,
                mime_type=Image.MIME.get(image.format or ""),
                image_format=image.format,
                color_mode=image.mode,
                width=image.width,
                height=image.height,
                frame_count=getattr(image, "n_frames", 1),
                orientation=_as_int(flattened.get("Orientation")),
                taken_at=_taken_at(flattened),
                camera_make=_as_text(flattened.get("Make")),
                camera_model=_as_text(flattened.get("Model")),
                lens_model=_as_text(flattened.get("LensModel")),
                software=_as_text(flattened.get("Software")),
                gps_latitude=latitude,
                gps_longitude=longitude,
                gps_altitude=altitude,
                exif=sections,
                container_metadata={
                    key: _container_value(value) for key, value in image.info.items()
                },
            )
    except Exception as error:  # noqa: BLE001 - catalog corrupt files with their error.
        return ImageMetadata(
            **common,
            mime_type=None,
            image_format=None,
            color_mode=None,
            width=None,
            height=None,
            frame_count=None,
            orientation=None,
            taken_at=None,
            camera_make=None,
            camera_model=None,
            lens_model=None,
            software=None,
            gps_latitude=None,
            gps_longitude=None,
            gps_altitude=None,
            exif={},
            container_metadata={},
            extraction_error=f"{type(error).__name__}: {error}",
        )


def _extract_exif_sections(exif: Any) -> dict[str, dict[str, Any]]:
    sections = {"ifd0": _named_tags(dict(exif.items()), ExifTags.TAGS)}
    ifd_names = {
        "exif": ExifTags.IFD.Exif,
        "gps": ExifTags.IFD.GPSInfo,
        "interop": ExifTags.IFD.Interop,
        "ifd1": ExifTags.IFD.IFD1,
    }
    for name, ifd in ifd_names.items():
        try:
            values = dict(exif.get_ifd(ifd).items())
        except (KeyError, TypeError, AttributeError, SyntaxError):
            continue
        if values:
            names = ExifTags.GPSTAGS if name == "gps" else ExifTags.TAGS
            sections[name] = _named_tags(values, names)
    return sections


def _named_tags(values: dict[Any, Any], names: dict[int, str]) -> dict[str, Any]:
    return {str(names.get(key, key)): _json_value(value) for key, value in values.items()}


def _json_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, IFDRational):
        return {
            "numerator": value.numerator,
            "denominator": value.denominator,
            "decimal": float(value),
        }
    if isinstance(value, bytes):
        return {"encoding": "base64", "value": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (tuple, list)):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    return str(value)


def _container_value(value: Any) -> Any:
    if isinstance(value, bytes):
        return {
            "type": "binary",
            "size_bytes": len(value),
            "sha256": hashlib.sha256(value).hexdigest(),
        }
    return _json_value(value)


def _gps_coordinates(gps: dict[str, Any]) -> tuple[float | None, float | None, float | None]:
    latitude = _dms(gps.get("GPSLatitude"))
    longitude = _dms(gps.get("GPSLongitude"))
    if latitude is not None and str(gps.get("GPSLatitudeRef", "N")).upper() == "S":
        latitude = -latitude
    if longitude is not None and str(gps.get("GPSLongitudeRef", "E")).upper() == "W":
        longitude = -longitude
    altitude = _number(gps.get("GPSAltitude"))
    if altitude is not None and _as_int(gps.get("GPSAltitudeRef")) == 1:
        altitude = -altitude
    return latitude, longitude, altitude


def _dms(value: Any) -> float | None:
    if not isinstance(value, list) or len(value) != 3:
        return None
    parts = [_number(item) for item in value]
    if any(item is None for item in parts):
        return None
    degrees, minutes, seconds = parts
    assert degrees is not None and minutes is not None and seconds is not None
    return degrees + minutes / 60 + seconds / 3600


def _number(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict) and "decimal" in value:
        return float(value["decimal"])
    return None


def _taken_at(tags: dict[str, Any]) -> str | None:
    candidates = (
        ("DateTimeOriginal", "OffsetTimeOriginal"),
        ("DateTimeDigitized", "OffsetTimeDigitized"),
        ("DateTime", "OffsetTime"),
    )
    for date_key, offset_key in candidates:
        value = tags.get(date_key)
        if not isinstance(value, str):
            continue
        offset = tags.get(offset_key)
        try:
            if isinstance(offset, str):
                return datetime.strptime(f"{value}{offset}", "%Y:%m:%d %H:%M:%S%z").isoformat()
            # EXIF date without an offset is intentionally preserved as local wall time.
            return datetime.strptime(value, "%Y:%m:%d %H:%M:%S").isoformat()  # noqa: DTZ007
        except ValueError:
            continue
    return None


def _relative_path(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return path.name


def _as_int(value: Any) -> int | None:
    return int(value) if isinstance(value, (int, float)) else None


def _as_text(value: Any) -> str | None:
    return str(value).strip() if value is not None else None


def _created_at(stat: Any) -> str | None:
    value = getattr(stat, "st_birthtime", None)
    return datetime.fromtimestamp(value, timezone.utc).isoformat() if value is not None else None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

