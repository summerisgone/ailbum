import json
import sqlite3
from pathlib import Path

from PIL import Image

from ailbum.catalog import index_library
from ailbum.database import connect, database_summary, get_catalog_image, list_catalog_images
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


def test_database_v2_faces_are_migrated_without_losing_rows(tmp_path: Path) -> None:
    database = tmp_path / "catalog.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute(
            """
            CREATE TABLE faces (
                id INTEGER PRIMARY KEY, run_id TEXT, image_id INTEGER, face_id TEXT,
                face_index INTEGER, bbox_x INTEGER, bbox_y INTEGER, bbox_width INTEGER,
                bbox_height INTEGER, confidence REAL, person_cluster INTEGER,
                person_id INTEGER, embedding BLOB, embedding_dim INTEGER,
                embedding_model TEXT, UNIQUE (run_id, face_id)
            )
            """
        )
        connection.execute(
            """
            INSERT INTO faces (
                run_id, image_id, face_id, face_index, bbox_x, bbox_y,
                bbox_width, bbox_height, confidence
            ) VALUES ('old-run', 1, 'old-face', 1, 10, 20, 30, 40, 0.9)
            """
        )
        connection.execute("PRAGMA user_version = 2")

    with connect(database) as connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(faces)")}
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        face_id = connection.execute("SELECT face_id FROM faces").fetchone()[0]

    assert version == 3
    assert face_id == "old-face"
    assert {"left_eye_state", "expression", "smile_probability"} <= columns
