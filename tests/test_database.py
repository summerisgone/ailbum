import json
import sqlite3
from pathlib import Path

from PIL import Image

from ailbum.catalog import index_library
from ailbum.database import database_summary, get_catalog_image, list_catalog_images
from ailbum.metadata import collect_image_metadata


def _write_image_with_exif(path: Path) -> None:
    exif = Image.Exif()
    exif[271] = "Ailbum Camera"
    exif[272] = "Test Model"
    exif[274] = 6
    exif[36867] = "2026:08:07 12:34:56"
    Image.new("RGB", (120, 80), (20, 100, 180)).save(path, exif=exif)


def test_collects_paths_hash_and_exif(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    path = source / "sample.jpg"
    _write_image_with_exif(path)

    metadata = collect_image_metadata(path, source)

    assert metadata.path == str(path.resolve())
    assert metadata.relative_path == "sample.jpg"
    assert metadata.sha256 and len(metadata.sha256) == 64
    assert metadata.camera_make == "Ailbum Camera"
    assert metadata.camera_model == "Test Model"
    assert metadata.taken_at == "2026-08-07T12:34:56"
    assert metadata.orientation == 6
    assert metadata.width == 120
    assert metadata.height == 80


def test_index_library_creates_queryable_catalog(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    _write_image_with_exif(source / "sample.jpg")
    database = tmp_path / "catalog.sqlite3"

    indexed = index_library(source, database)
    summary = database_summary(database)
    images = list_catalog_images(database)
    details = get_catalog_image(database, images[0]["id"])

    assert indexed == {"images": 1, "available": 1, "errors": 0}
    assert summary["images"] == 1
    assert summary["unique_files"] == 1
    assert summary["with_taken_at"] == 1
    assert images[0]["path"] == str((source / "sample.jpg").resolve())
    assert details["exif"]["ifd0"]["Model"] == "Test Model"
    assert details["analysis_history"] == []

    with sqlite3.connect(database) as connection:
        exif_json = connection.execute("SELECT exif_json FROM images").fetchone()[0]
    exif = json.loads(exif_json)
    assert exif["ifd0"]["Make"] == "Ailbum Camera"
