import sqlite3
from pathlib import Path

import pytest

from ailbum.database import SCHEMA_VERSION, connect


def _v11(path: Path) -> None:
    """Build a v11 database by creating the current schema and reshaping it."""
    c = sqlite3.connect(path)
    c.executescript(
        """
        CREATE TABLE images (
            id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, source_root TEXT NOT NULL,
            relative_path TEXT NOT NULL, file_name TEXT NOT NULL, extension TEXT NOT NULL,
            file_size_bytes INTEGER NOT NULL, modified_at TEXT NOT NULL, created_at TEXT,
            sha256 TEXT NOT NULL, mime_type TEXT, image_format TEXT, color_mode TEXT,
            width INTEGER, height INTEGER, frame_count INTEGER, orientation INTEGER,
            taken_at TEXT, camera_make TEXT, camera_model TEXT, lens_model TEXT,
            software TEXT, gps_latitude REAL, gps_longitude REAL, gps_altitude REAL,
            exif_json TEXT NOT NULL, container_metadata_json TEXT NOT NULL,
            extraction_error TEXT, indexed_at TEXT NOT NULL,
            missing INTEGER NOT NULL DEFAULT 0 CHECK (missing IN (0, 1)));
        CREATE TABLE analysis_runs (
            id TEXT PRIMARY KEY, source TEXT NOT NULL, output TEXT NOT NULL,
            started_at TEXT NOT NULL, completed_at TEXT NOT NULL, face_backend TEXT NOT NULL,
            config_json TEXT NOT NULL, summary_json TEXT NOT NULL, status TEXT NOT NULL);
        CREATE TABLE photo_analysis (
            run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
            photo_id TEXT NOT NULL, sharpness REAL NOT NULL, exposure REAL NOT NULL,
            quality REAL NOT NULL, is_blurry INTEGER NOT NULL, similar_cluster INTEGER,
            story_id INTEGER, selected INTEGER NOT NULL, error TEXT,
            PRIMARY KEY (run_id, image_id), UNIQUE (run_id, photo_id));
        CREATE TABLE faces (
            id INTEGER PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
            face_id TEXT NOT NULL, face_index INTEGER NOT NULL, bbox_x INTEGER NOT NULL,
            bbox_y INTEGER NOT NULL, bbox_width INTEGER NOT NULL, bbox_height INTEGER NOT NULL,
            confidence REAL NOT NULL, person_cluster INTEGER, person_id INTEGER,
            UNIQUE (run_id, face_id));
        CREATE TABLE photo_selections (
            run_id TEXT NOT NULL REFERENCES analysis_runs(id) ON DELETE CASCADE,
            image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
            selected_at TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (run_id, image_id));
        CREATE TABLE desktop_run_settings (
            run_id TEXT PRIMARY KEY REFERENCES analysis_runs(id) ON DELETE CASCADE,
            target_count INTEGER NOT NULL DEFAULT 24, selection_initialized INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL);
        CREATE TABLE layouts (
            id INTEGER PRIMARY KEY,
            run_id TEXT NOT NULL UNIQUE REFERENCES analysis_runs(id) ON DELETE CASCADE,
            orientation TEXT NOT NULL, spread_count INTEGER NOT NULL, min_photos INTEGER NOT NULL,
            max_photos INTEGER NOT NULL, selection_hash TEXT NOT NULL, assistant_model TEXT,
            unplaced_json TEXT NOT NULL DEFAULT '[]', warnings_json TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE TABLE layout_spreads (
            id INTEGER PRIMARY KEY,
            layout_id INTEGER NOT NULL REFERENCES layouts(id) ON DELETE CASCADE,
            position INTEGER NOT NULL, template_id TEXT NOT NULL,
            story_ids_json TEXT NOT NULL DEFAULT '[]', warnings_json TEXT NOT NULL DEFAULT '[]',
            assistant_reason TEXT, UNIQUE (layout_id, position));
        CREATE TABLE layout_placements (
            spread_id INTEGER NOT NULL REFERENCES layout_spreads(id) ON DELETE CASCADE,
            cell_index INTEGER NOT NULL,
            image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
            crop_x REAL NOT NULL, crop_y REAL NOT NULL, crop_w REAL NOT NULL, crop_h REAL NOT NULL,
            fit REAL NOT NULL, warnings_json TEXT NOT NULL DEFAULT '[]', replaced_image_id INTEGER,
            PRIMARY KEY (spread_id, cell_index));
        PRAGMA user_version = 11;
        """
    )
    for i in range(1, 5):
        c.execute(
            "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,"
            " indexed_at, missing) VALUES (?, ?, '/p/Турция', ?, ?, '.jpg', 1, 't', ?, '{}', '{}',"
            " 't', ?)",
            (i, f"/p/Турция/{i}.jpg", f"{i}.jpg", f"{i}.jpg", f"sha{i}", 1 if i == 4 else 0),
        )
    for run, source in (("r1", "/p/Турция"), ("r2", "/p/Лето")):
        c.execute(
            "INSERT INTO analysis_runs VALUES (?, ?, 'o', 't', 't', 'classic', '{}', '{}', 'completed')",
            (run, source),
        )
    for i in (1, 2, 3):
        c.execute(
            "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,"
            " is_blurry, selected) VALUES ('r1', ?, ?, 1, 1, 1, 0, ?)",
            (i, f"p{i}", 1),
        )
    c.execute("INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
              " bbox_width, bbox_height, confidence) VALUES ('r1', 1, 'f', 1, 0, 0, 1, 1, .9)")
    # final selection {1,2,4}: 3 removed, 4 added
    for pos, i in ((1, 4), (2, 1), (3, 2)):
        c.execute("INSERT INTO photo_selections VALUES ('r1', ?, 'sel', ?)", (i, pos))
    c.execute("INSERT INTO desktop_run_settings VALUES ('r2', 40, 1, 't')")
    c.execute("INSERT INTO layouts (id, run_id, orientation, spread_count, min_photos, max_photos,"
              " selection_hash, created_at, updated_at) VALUES (7, 'r1', 'landscape', 2, 1, 4,"
              " 'h', 't', 't')")
    c.execute("INSERT INTO layout_spreads (id, layout_id, position, template_id) VALUES (3, 7, 1, 'x')")
    c.execute("INSERT INTO layout_placements VALUES (3, 0, 1, 0, 0, 1, 1, 1, '[]', NULL)")
    c.commit()
    c.close()


@pytest.fixture
def v11(tmp_path: Path) -> Path:
    path = tmp_path / "db.sqlite3"
    _v11(path)
    return path


def test_migrate_keeps_rows(v11: Path) -> None:
    with connect(v11) as c:
        albums = c.execute("SELECT * FROM albums ORDER BY run_id").fetchall()
        assert [(a["title"], a["status"], a["run_id"], a["target_count"]) for a in albums] == [
            ("Турция", "draft", "r1", 24),
            ("Лето", "draft", "r2", 40),
        ]
        a1 = albums[0]["id"]
        photos = c.execute(
            "SELECT image_id, position, added_at FROM album_photos WHERE album_id = ? "
            "ORDER BY position", (a1,)).fetchall()
        assert [tuple(p) for p in photos] == [(4, 1, "sel"), (1, 2, "sel"), (2, 3, "sel")]
        assert c.execute("SELECT source_root FROM album_sources WHERE album_id = ?", (a1,)
                         ).fetchone()[0] == "/p/Турция"
        layout = c.execute("SELECT album_id, run_id FROM layouts").fetchone()
        assert tuple(layout) == (a1, "r1")
        assert c.execute("SELECT COUNT(*) FROM layout_spreads").fetchone()[0] == 1
        assert c.execute("SELECT COUNT(*) FROM layout_placements").fetchone()[0] == 1
        assert c.execute("SELECT COUNT(*) FROM album_photos").fetchone()[0] == 3
        tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert not tables & {"photo_selections", "desktop_run_settings"}
        assert c.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION == 12
        assert c.execute("PRAGMA foreign_keys").fetchone()[0] == 1


def test_backfill_counts_differences(v11: Path) -> None:
    with connect(v11) as c:
        rows = c.execute(
            "SELECT image_id, action, source, run_id FROM selection_events ORDER BY id"
        ).fetchall()
    assert [tuple(r) for r in rows] == [(4, "add", "backfill", "r1"), (3, "remove", "backfill", "r1")]


def test_restrict_blocks_image_delete(v11: Path) -> None:
    with connect(v11) as c:
        with pytest.raises(sqlite3.IntegrityError):
            c.execute("DELETE FROM images WHERE id = 1")


def test_migrate_idempotent(v11: Path) -> None:
    with connect(v11) as c:
        before = c.execute("SELECT COUNT(*) FROM albums").fetchone()[0]
    with connect(v11) as c:
        assert c.execute("SELECT COUNT(*) FROM albums").fetchone()[0] == before == 2
        assert c.execute("SELECT COUNT(*) FROM selection_events").fetchone()[0] == 2


def test_missing_maps_to_availability(v11: Path) -> None:
    with connect(v11) as c:
        got = {r[0]: r[1] for r in c.execute("SELECT id, availability FROM images")}
    assert got == {1: "present", 2: "present", 3: "present", 4: "missing"}


def test_fresh_db_v12(tmp_path: Path) -> None:
    with connect(tmp_path / "f.sqlite3") as c:
        tables = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert {"albums", "album_sources", "album_photos", "album_exports",
                "selection_events", "ranking_models"} <= tables
        assert not tables & {"photo_selections", "desktop_run_settings"}
        cols = {r[1] for r in c.execute("PRAGMA table_info(images)")}
        assert "availability" in cols and "missing" not in cols
        assert {"album_id", "prompt"} <= {r[1] for r in c.execute("PRAGMA table_info(layouts)")}
        assert c.execute("PRAGMA user_version").fetchone()[0] == 12
