import base64
import io
import json

import pytest

from ailbum import albums, desktop_bridge, proxies
from ailbum.database import connect


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "a.db"
    with connect(path) as c:
        c.execute(
            "INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','none','{}','{}','completed')"
        )
        for i in range(1, 4):
            c.execute(
                """INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
                   file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,
                   indexed_at) VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024', ?, '{}', '{}', 't')""",
                (i, f"/p/{i}.jpg", f"{i}.jpg", f"{i}.jpg", f"sha{i}"),
            )
            c.execute(
                """INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,
                   quality, is_blurry, story_id, selected) VALUES ('r1', ?, ?, 0.5, 0.5, 0.5, 0, 1, 0)""",
                (i, f"p{i}"),
            )
        albums.create_album(c, "T", ["/p"], run_id="r1", target_count=2)
    return path


def call(db, action, **payload):
    return desktop_bridge._dispatch(db, action, payload)


def test_library_bootstrap_has_media_path(db):
    data = call(db, "library.bootstrap", album_id=1)
    assert data["album"]["id"] == 1 and data["selected_count"] == 2
    assert all("media_path" in p for p in data["photos"])
    assert call(db, "library.bootstrap")["album"]["id"] == 1


def test_media_path_uses_image_source(db, monkeypatch):
    monkeypatch.setattr(proxies, "image_source", lambda d, img: db.parent / f"{img['sha256']}.jpg")
    photos = call(db, "library.bootstrap", album_id=1)["photos"]
    assert photos[0]["media_path"].endswith("sha1.jpg")


def test_selection_actions(db):
    r = call(db, "favorite.set", album_id=1, image_id=3, favorite=True)
    assert r["favorite"] is True
    assert call(db, "target.set", album_id=1, target_count=3)["target_count"] == 3
    assert call(db, "selection.autofill", album_id=1)["selected_count"] == 3
    assert len(call(db, "album.list")) == 1


def test_album_lifecycle_actions(db):
    assert call(db, "album.rename", album_id=1, title="Новый")["title"] == "Новый"
    assert call(db, "album.status", album_id=1, status="ordered")["status"] == "ordered"
    plan = call(db, "album.prepare_archive", album_id=1)
    assert plan["album_id"] == 1
    assert call(db, "album.complete_archive", album_id=1, trashed=[])["archived"] == 0
    assert call(db, "album.confirm_missing", image_ids=[1]) == {"confirmed": 0}


def test_album_delete(db):
    assert call(db, "album.delete", album_id=1, forget_decisions=False) == {"deleted": True}
    assert call(db, "album.list") == []


def test_usage(db):
    pytest.importorskip("ailbum.forget")
    assert "images" in call(db, "album.usage")


def test_face_thumbnail(db, monkeypatch):
    monkeypatch.setattr(proxies, "face_thumbnail", lambda d, f: b"jpg" + bytes([f]))
    out = call(db, "face.thumbnail", face_id=5)
    assert out["mime_type"] == "image/jpeg"
    assert base64.b64decode(out["base64"]) == b"jpg\x05"


def test_face_thumbnail_without_source_is_null(db, monkeypatch):
    monkeypatch.setattr(proxies, "face_thumbnail", lambda d, f: None)
    assert call(db, "face.thumbnail", face_id=5) is None


def test_unknown_and_error_response(db, monkeypatch, capsys):
    with pytest.raises(ValueError):
        call(db, "nope")
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps({"id": 1, "action": "favorite.set",
        "payload": {"album_id": 99, "image_id": 1, "favorite": True}}) + "\n"))
    desktop_bridge.serve(db)
    out = json.loads(capsys.readouterr().out)
    assert out["id"] == 1 and "error" in out
