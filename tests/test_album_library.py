import json
from pathlib import Path

import pytest

from ailbum import album_library as lib
from ailbum import albums
from ailbum.database import connect


def _populate(db: Path, n: int = 6, missing: tuple = ()):
    with connect(db) as c:
        c.execute(
            "INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','none','{}','{}','completed')"
        )
        for i in range(1, n + 1):
            avail = "archived" if i in missing else "present"
            c.execute(
                """INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
                   file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,
                   indexed_at, availability)
                   VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024-01-01', ?, '{}', '{}', 't', ?)""",
                (i, f"/p/{i}.jpg", f"{i}.jpg", f"{i}.jpg", f"sha{i}", avail),
            )
            c.execute(
                """INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,
                   quality, is_blurry, story_id, selected)
                   VALUES ('r1', ?, ?, 0.5, 0.5, ?, 0, ?, 0)""",
                (i, f"p{i}", i / 10, i % 2),
            )
        aid = albums.create_album(c, "T", ["/p"], run_id="r1", target_count=3)
    return aid


def test_set_photo_event_only_on_change(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db)
    with connect(db) as c:
        r = lib.set_photo(c, aid, 2, True)
        assert r == {"album_id": aid, "image_id": 2, "favorite": True, "changed": True, "selected_count": 1}
        assert lib.set_photo(c, aid, 2, True)["changed"] is False
        assert lib.set_photo(c, aid, 3, False)["changed"] is False
        assert lib.set_photo(c, aid, 2, False)["changed"] is True
        events = c.execute("SELECT action, source, run_id FROM selection_events").fetchall()
        assert [tuple(e) for e in events] == [("add", "manual", "r1"), ("remove", "manual", "r1")]


def test_set_photo_non_draft_and_foreign_image(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db)
    with connect(db) as c:
        with pytest.raises(ValueError):
            lib.set_photo(c, aid, 99, True)
        albums.set_status(c, aid, "ordered")
        with pytest.raises(ValueError, match="Альбом заказан"):
            lib.set_photo(c, aid, 1, True)
        with pytest.raises(ValueError):
            lib.set_target(c, aid, 5)
        with pytest.raises(ValueError):
            lib.autofill(c, aid)


def test_selection_hash(tmp_path):
    import hashlib

    db = tmp_path / "a.db"
    aid = _populate(db)
    with connect(db) as c:
        lib.set_photo(c, aid, 3, True)
        lib.set_photo(c, aid, 1, True)
        assert lib.selection_hash(c, aid) == hashlib.sha256(b"1,3").hexdigest()


def test_set_target_bounds(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db)
    with connect(db) as c:
        for bad in (0, 1000):
            with pytest.raises(ValueError):
                lib.set_target(c, aid, bad)
        assert lib.set_target(c, aid, 5)["target_count"] == 5


def test_first_open_seeds_target_count_once(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db)
    data = lib.get_library(db, aid)
    assert data["selected_count"] == 3 and data["target_count"] == 3
    with connect(db) as c:
        ev = c.execute("SELECT action, source FROM selection_events").fetchall()
        assert len(ev) == 3 and {tuple(e) for e in ev} == {("seed", "auto")}
    lib.get_library(db, aid)
    with connect(db) as c:
        assert c.execute("SELECT COUNT(*) FROM selection_events").fetchone()[0] == 3


def test_autofill_keeps_manual(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db)
    with connect(db) as c:
        lib.set_photo(c, aid, 1, True)
        res = lib.autofill(c, aid)
        assert res["selected_count"] == 3 and len(res["added"]) == 2 and 1 not in res["added"]
        ids = [r[0] for r in c.execute("SELECT image_id FROM album_photos ORDER BY position")]
        assert ids[0] == 1 and len(ids) == 3
        actions = c.execute(
            "SELECT action, source FROM selection_events WHERE source = 'auto'"
        ).fetchall()
        assert len(actions) == 2 and all(a["action"] == "add" for a in actions)


def test_library_lists_archived_with_availability(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db, missing=(6,))
    with connect(db) as c:
        lib.set_photo(c, aid, 6, True)
        lib.set_photo(c, aid, 1, True)
        lib.set_photo(c, aid, 2, True)
    data = lib.get_library(db, aid)
    by_id = {p["id"]: p for p in data["photos"]}
    assert by_id[6]["availability"] == "archived" and by_id[6]["favorite"] is True
    assert by_id[1]["availability"] == "present"
    assert data["album"]["id"] == aid and data["albums"][0]["id"] == aid
    assert data["run"]["id"] == "r1" and isinstance(data["run"]["summary"], dict)


def test_no_album(tmp_path):
    db = tmp_path / "a.db"
    with connect(db):
        pass
    data = lib.get_library(db, None)
    assert data["album"] is None and data["albums"] == [] and data["photos"] == []
    assert data["target_count"] == 24


def test_default_album_prefers_draft(tmp_path):
    db = tmp_path / "a.db"
    aid = _populate(db)
    with connect(db) as c:
        other = albums.create_album(c, "Z", ["/q"])
        albums.set_status(c, other, "ordered")
    assert lib.get_library(db, None)["album"]["id"] == aid
