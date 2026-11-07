from pathlib import Path

import numpy as np
import pytest

from ailbum import albums
from ailbum.database import connect
from ailbum.forget import forget, plan_forget, usage


def _emb(v: list[float]) -> bytes:
    return np.asarray(v, dtype=np.float32).tobytes()


@pytest.fixture
def db(tmp_path: Path) -> Path:
    path = tmp_path / "db.sqlite3"
    with connect(path) as c:
        for i, root in ((1, "/a"), (2, "/a"), (3, "/b")):
            c.execute(
                "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
                " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,"
                " indexed_at, availability) VALUES (?, ?, ?, 'x', 'x', '.jpg', 1, 't', ?, '{}',"
                " '{}', 't', ?)",
                (i, f"{root}/{i}.jpg", root, f"sha{i}", "archived" if i == 2 else "present"),
            )
        c.execute("INSERT INTO analysis_runs VALUES ('r', '/a', 'o', 't', 't', 'c', '{}', '{}',"
                  " 'completed')")
        for i in (1, 2):
            c.execute(
                "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,"
                " quality, is_blurry, selected) VALUES ('r', ?, ?, 1, 1, 1, 0, 1)", (i, f"p{i}"))
        for pid, vec in ((1, [1.0, 0.0]), (2, [0.0, 1.0])):
            c.execute(
                "INSERT INTO people (id, public_id, embedding_model, centroid_embedding,"
                " embedding_dim, created_at, updated_at) VALUES (?, ?, 'm', ?, 2, 't', 't')",
                (pid, f"u{pid}", _emb(vec)))
        # person 1: faces on image 1 and image 3; person 2: face on image 2 only
        for fid, img, pid, vec in ((1, 1, 1, [1.0, 0.0]), (2, 3, 1, [0.0, 1.0]),
                                   (3, 2, 2, [0.0, 1.0])):
            c.execute(
                "INSERT INTO faces (id, run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
                " bbox_width, bbox_height, confidence, person_id, embedding, embedding_dim,"
                " embedding_model) VALUES (?, 'r', ?, ?, 1, 0, 0, 1, 1, .9, ?, ?, 2, 'm')",
                (fid, img, f"f{fid}", pid, _emb(vec)))
        a = albums.create_album(c, "Лето", ["/a"], run_id="r")
        c.execute("INSERT INTO album_photos VALUES (?, 1, 1, 't')", (a,))
        c.execute("INSERT INTO selection_events (album_id, run_id, image_id, action, source,"
                  " created_at) VALUES (?, 'r', 1, 'add', 'manual', 't')", (a,))
    for rel in ("photos/sha1.jpg", "photos/sha2.jpg", "photos/sha3.jpg", "faces/1.jpg",
                "faces/3.jpg", "faces/2.jpg"):
        f = tmp_path / "proxies" / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b"xx")
    return path


def test_exactly_one_scope(db: Path) -> None:
    with pytest.raises(ValueError):
        plan_forget(db, None, None)
    with pytest.raises(ValueError):
        plan_forget(db, 1, "/a")


def test_plan_has_no_writes(db: Path) -> None:
    plan = plan_forget(db, None, "/a")
    assert plan["images"] == 2 and plan["faces"] == 2
    assert plan["people_affected"] == [1, 2] and plan["people_removed"] == [2]
    assert plan["albums_affected"] == [{"id": 1, "title": "Лето"}]
    assert plan["events"] == 1 and plan["proxies"] == 4
    with connect(db) as c:
        assert c.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 3


def test_forget_source(db: Path) -> None:
    result = forget(db, None, "/a")
    assert result["done"] is True
    with connect(db) as c:
        assert [r[0] for r in c.execute("SELECT id FROM images")] == [3]
        assert [r[0] for r in c.execute("SELECT id FROM people")] == [1]
        assert c.execute("SELECT COUNT(*) FROM album_photos").fetchone()[0] == 0
        assert c.execute("SELECT COUNT(*) FROM selection_events").fetchone()[0] == 0
        assert c.execute("SELECT COUNT(*) FROM albums").fetchone()[0] == 1
        centroid = np.frombuffer(
            c.execute("SELECT centroid_embedding FROM people WHERE id = 1").fetchone()[0],
            dtype=np.float32)
        assert np.allclose(centroid, [0.0, 1.0])
    p = db.parent / "proxies"
    assert not (p / "photos/sha1.jpg").exists() and not (p / "faces/1.jpg").exists()
    assert (p / "photos/sha3.jpg").exists() and (p / "faces/2.jpg").exists()


def test_forget_album_deletes_album(db: Path) -> None:
    forget(db, 1, None)
    with connect(db) as c:
        assert c.execute("SELECT COUNT(*) FROM albums").fetchone()[0] == 0
        assert [r[0] for r in c.execute("SELECT id FROM images")] == [3]


def test_shared_sha_keeps_photo_proxy(db: Path) -> None:
    with connect(db) as c:
        c.execute("UPDATE images SET sha256 = 'sha1' WHERE id = 3")
    forget(db, None, "/a")
    assert (db.parent / "proxies/photos/sha1.jpg").exists()


def test_usage(db: Path) -> None:
    (db.parent / "feature-cache").mkdir()
    (db.parent / "feature-cache" / "a.npz").write_bytes(b"123")
    u = usage(db)
    assert u["proxies_bytes"] == 12 and u["feature_cache_bytes"] == 3
    assert u["database_bytes"] > 0
    assert u["images"] == {"present": 2, "missing": 0, "archived": 1}
