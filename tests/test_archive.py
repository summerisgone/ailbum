import json
from pathlib import Path

import pytest
from PIL import Image

from ailbum import albums, archive
from ailbum.database import connect
from ailbum.layout.export import export_originals


@pytest.fixture
def env(tmp_path):
    db = tmp_path / "db" / "a.sqlite"
    src = tmp_path / "Мои фото"
    src.mkdir()
    with connect(db) as c:
        c.execute("INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','x','{}','{}','completed')")
    return db, src


def add_image(db, src, n, sha=None, color=(10, 20, 30)):
    path = src / f"фото {n}.jpg"
    Image.new("RGB", (64, 48), color).save(path)
    with connect(db) as c:
        c.execute(
            "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
            " VALUES (?, ?, ?, 'a', ?, 'jpg', 1, 't', ?, '{}', '{}', 't')",
            (n, str(path), str(src), path.name, sha or f"sha{n}"),
        )
    return path


def make_album(db, ids, title="Альбом", layout=True):
    with connect(db) as c:
        a = albums.create_album(c, title, ["/p"], "r1")
        for pos, i in enumerate(ids):
            c.execute("INSERT INTO album_photos VALUES (?, ?, ?, 't')", (a, i, pos))
        if layout:
            cur = c.execute(
                "INSERT INTO layouts (album_id, run_id, orientation, spread_count, min_photos,"
                " max_photos, selection_hash, created_at, updated_at)"
                " VALUES (?, 'r1', 'landscape', 1, 1, 4, 'h', 't', 't')",
                (a,),
            )
            sp = c.execute(
                "INSERT INTO layout_spreads (layout_id, position, template_id) VALUES (?, 1, 't')",
                (cur.lastrowid,),
            ).lastrowid
            for cell, i in enumerate(ids):
                c.execute(
                    "INSERT INTO layout_placements (spread_id, cell_index, image_id, crop_x, crop_y,"
                    " crop_w, crop_h, fit) VALUES (?, ?, ?, 0, 0, 1, 1, 1)",
                    (sp, cell, i),
                )
    return a


def test_export_logs_and_skips_missing(env, tmp_path):
    db, src = env
    add_image(db, src, 1)
    add_image(db, src, 2)
    with connect(db) as c:
        c.execute("UPDATE images SET availability='missing' WHERE id=2")
    a = make_album(db, [1, 2])
    out = tmp_path / "Выгрузка"
    out.mkdir()
    r = export_originals(db, a, out)
    assert r["count"] == 1 and len(r["missing"]) == 1 and r["export_id"]
    with connect(db) as c:
        row = c.execute("SELECT * FROM album_exports").fetchone()
        assert json.loads(row["missing_json"]) == r["missing"]


def test_prepare_needs_export_then_trash(env, tmp_path):
    db, src = env
    p1 = add_image(db, src, 1)
    a = make_album(db, [1])
    r = archive.prepare_archive(db, a)
    assert r["needs_export"] is True and r["trash"] == []
    with connect(db) as c:
        assert albums.get_album(c, a)["status"] == "ordered"
    export_originals(db, a, tmp_path)
    r = archive.prepare_archive(db, a)
    assert r["needs_export"] is False and r["trash"] == [str(p1)] and r["blocked"] == []
    assert (db.parent / "proxies" / "photos" / "sha1.jpg").is_file()


def test_no_layout_no_export_needed_and_shared_blocked(env):
    db, src = env
    add_image(db, src, 1)
    add_image(db, src, 2)
    a = make_album(db, [1, 2], "Первый", layout=False)
    make_album(db, [2], "Лето", layout=False)
    r = archive.prepare_archive(db, a)
    assert r["needs_export"] is False
    assert len(r["trash"]) == 1
    assert r["blocked"] == [{"image_id": 2, "reason": "входит в черновик «Лето»"}]


def test_unbuildable_proxy_never_trashed(env):
    db, src = env
    p = add_image(db, src, 1)
    p.write_bytes(b"not an image")
    a = make_album(db, [1], layout=False)
    r = archive.prepare_archive(db, a)
    assert r["trash"] == [] and r["blocked"][0]["reason"].startswith("не удалось построить превью")


def test_complete_archive(env):
    db, src = env
    p1 = add_image(db, src, 1, sha="same")
    p2 = add_image(db, src, 2, sha="same")
    p3 = add_image(db, src, 3)
    a = make_album(db, [1, 3], layout=False)
    cache = db.parent / "feature-cache" / "m"
    cache.mkdir(parents=True)
    (cache / "same.npz").write_bytes(b"x")
    (cache / "sha3.npz").write_bytes(b"x")
    archive.prepare_archive(db, a)
    p1.unlink()
    outside = Path(str(p2))
    r = archive.complete_archive(db, a, [str(p1), str(outside)])
    assert r["archived"] == 1 and r["status"] == "ordered"
    assert (cache / "same.npz").exists()  # image 2 with same sha still present
    p3.unlink()
    r = archive.complete_archive(db, a, [str(p3)])
    assert r["status"] == "archived" and r["cache_removed"] == 1
    assert not (cache / "sha3.npz").exists() and (cache / "same.npz").exists()
    with connect(db) as c:
        assert c.execute("SELECT availability FROM images WHERE id=2").fetchone()[0] == "present"


def test_cache_removed_when_no_present_same_sha(env):
    db, src = env
    p1 = add_image(db, src, 1)
    a = make_album(db, [1], layout=False)
    cache = db.parent / "feature-cache" / "m"
    cache.mkdir(parents=True)
    (cache / "sha1.npz").write_bytes(b"x")
    archive.prepare_archive(db, a)
    p1.unlink()
    assert archive.complete_archive(db, a, [str(p1)])["cache_removed"] == 1


def test_trash_paths_backend(env, monkeypatch):
    calls = []
    import sys
    import types

    def fake(path):
        calls.append(path)
        if path.endswith("bad"):
            raise OSError("x")

    monkeypatch.setitem(sys.modules, "send2trash", types.SimpleNamespace(send2trash=fake))
    assert archive.trash_paths(["/t/a b", "/t/bad", "/t/ё"]) == ["/t/a b", "/t/ё"]


def test_confirm_missing(env):
    db, src = env
    add_image(db, src, 1)
    add_image(db, src, 2)
    with connect(db) as c:
        c.execute("UPDATE images SET availability='missing' WHERE id=1")
    assert archive.confirm_missing(db, [1, 2]) == 1
    with connect(db) as c:
        assert c.execute("SELECT availability FROM images WHERE id=1").fetchone()[0] == "archived"
