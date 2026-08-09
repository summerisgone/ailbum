import json
import sqlite3
from pathlib import Path

from PIL import Image

from ailbum.catalog import index_library
from ailbum.database import (
    connect,
    database_summary,
    get_catalog_image,
    get_desktop_library,
    list_catalog_images,
    set_desktop_favorite,
    set_desktop_target,
)
from ailbum.metadata import collect_image_metadata


def _write_image_with_exif(path: Path, taken_at: str = "2026:08:07 12:34:56") -> None:
    exif = Image.Exif()
    exif[271] = "Ailbum Camera"
    exif[272] = "Test Model"
    exif[274] = 6
    exif[36867] = taken_at
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
    assert summary["stories"] == 0
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

    assert version == 8
    assert face_id == "old-face"
    assert {"left_eye_state", "expression", "smile_probability"} <= columns


def test_database_v5_photo_metrics_are_migrated_without_losing_rows(tmp_path: Path) -> None:
    database = tmp_path / "catalog.sqlite3"
    with sqlite3.connect(database) as connection:
        connection.execute(
            """
            CREATE TABLE photo_analysis (
                run_id TEXT NOT NULL, image_id INTEGER NOT NULL, photo_id TEXT NOT NULL,
                sharpness REAL NOT NULL, exposure REAL NOT NULL, quality REAL NOT NULL,
                is_blurry INTEGER NOT NULL, similar_cluster INTEGER,
                selected INTEGER NOT NULL, error TEXT,
                PRIMARY KEY (run_id, image_id)
            )
            """
        )
        connection.execute(
            """
            INSERT INTO photo_analysis (
                run_id, image_id, photo_id, sharpness, exposure, quality,
                is_blurry, selected
            ) VALUES ('old-run', 1, 'old-photo', 123, 0.8, 0.9, 0, 1)
            """
        )
        connection.execute("PRAGMA user_version = 5")

    with connect(database) as connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(photo_analysis)")}
        row = connection.execute(
            "SELECT photo_id, scene_tags_json FROM photo_analysis"
        ).fetchone()

    assert {"aesthetic_score", "color_harmony", "object_tags_json", "story_id"} <= columns
    assert tuple(row) == ("old-photo", "[]")


def test_desktop_library_initializes_manual_selection_from_analysis_once(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    _write_image_with_exif(source / "sample.jpg")
    database = tmp_path / "catalog.sqlite3"
    index_library(source, database)

    with connect(database) as connection:
        image_id = connection.execute("SELECT id FROM images").fetchone()[0]
        connection.execute(
            """
            INSERT INTO analysis_runs (
                id, source, output, started_at, completed_at, face_backend,
                config_json, summary_json, status
            ) VALUES ('run-1', ?, ?, '2026-08-07T10:00:00+00:00',
                      '2026-08-07T10:01:00+00:00', 'classic',
                      '{"story_naming_backend":"rules"}', '{}', 'completed')
            """,
            (str(source), str(tmp_path / "output")),
        )
        connection.execute(
            """
            INSERT INTO photo_analysis (
                run_id, image_id, photo_id, sharpness, exposure, quality,
                is_blurry, similar_cluster, selected, error
            ) VALUES ('run-1', ?, 'photo-1', 120, 0.8, 0.9, 0, 2, 1, NULL)
            """,
            (image_id,),
        )

    library = get_desktop_library(database)
    assert library["run"]["id"] == "run-1"  # type: ignore[index]
    assert library["photos"][0]["auto_selected"] is True  # type: ignore[index]
    assert library["photos"][0]["favorite"] is True  # type: ignore[index]
    assert library["selected_count"] == 1
    assert library["stories"][0]["title"] == "Сюжет без названия 1"  # type: ignore[index]
    assert library["photos"][0]["story_id"] == 1  # type: ignore[index]

    set_desktop_favorite(database, "run-1", image_id, False)
    set_desktop_target(database, "run-1", 36)
    updated = get_desktop_library(database)

    assert updated["selected_count"] == 0
    assert updated["target_count"] == 36
    assert updated["photos"][0]["auto_selected"] is True  # type: ignore[index]
    assert updated["photos"][0]["favorite"] is False  # type: ignore[index]


def test_desktop_library_backfills_and_returns_multiple_stories(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    _write_image_with_exif(source / "morning.jpg", "2026:08:07 09:00:00")
    _write_image_with_exif(source / "evening.jpg", "2026:08:07 17:00:00")
    database = tmp_path / "catalog.sqlite3"
    index_library(source, database)

    with connect(database) as connection:
        images = connection.execute("SELECT id FROM images ORDER BY taken_at").fetchall()
        connection.execute(
            """
            INSERT INTO analysis_runs (
                id, source, output, started_at, completed_at, face_backend,
                config_json, summary_json, status
            ) VALUES ('run-stories', ?, ?, '2026-08-07T18:00:00+00:00',
                      '2026-08-07T18:01:00+00:00', 'classic',
                      '{"story_naming_backend":"rules"}', '{}', 'completed')
            """,
            (str(source), str(tmp_path / "output")),
        )
        for index, image in enumerate(images, start=1):
            connection.execute(
                """
                INSERT INTO photo_analysis (
                    run_id, image_id, photo_id, sharpness, exposure, quality,
                    is_blurry, selected
                ) VALUES ('run-stories', ?, ?, 120, 0.8, 0.9, 0, 1)
                """,
                (image["id"], f"photo-{index}"),
            )

    library = get_desktop_library(database)

    assert [story["id"] for story in library["stories"]] == [1, 2]  # type: ignore[index]
    assert [photo["story_id"] for photo in library["photos"]] == [1, 2]  # type: ignore[index]
