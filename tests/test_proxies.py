import sqlite3
from io import BytesIO
from pathlib import Path

from PIL import Image

from ailbum import proxies


def make_db(tmp_path: Path, images: list[tuple], faces: list[tuple] = ()) -> Path:
    db = tmp_path / "db" / "a.sqlite"
    db.parent.mkdir()
    c = sqlite3.connect(db)
    c.execute(
        "CREATE TABLE images (id INTEGER PRIMARY KEY, path TEXT, sha256 TEXT, availability TEXT,"
        " width INTEGER, height INTEGER, orientation INTEGER)"
    )
    c.execute(
        "CREATE TABLE faces (id INTEGER PRIMARY KEY, image_id INTEGER, bbox_x INTEGER,"
        " bbox_y INTEGER, bbox_width INTEGER, bbox_height INTEGER)"
    )
    c.executemany("INSERT INTO images VALUES (?,?,?,?,?,?,?)", images)
    c.executemany("INSERT INTO faces VALUES (?,?,?,?,?,?)", faces)
    c.commit()
    c.close()
    return db


def jpeg(path: Path, size=(3000, 2000), orientation=None, color=(200, 30, 30)):
    path.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", size, color)
    if orientation:
        exif = Image.Exif()
        exif[274] = orientation
        image.save(path, "JPEG", exif=exif)
    else:
        image.save(path, "JPEG")


def test_build_resizes_and_reuses(tmp_path):
    src = tmp_path / "Мои фото" / "а б.jpg"
    jpeg(src)
    db = make_db(tmp_path, [(1, str(src), "ab", "present", 3000, 2000, 1)], [(7, 1, 100, 100, 200, 200)])
    result = proxies.build_proxies(db, [1])
    assert result == {"built": [1], "failed": []}
    out = tmp_path / "db" / "proxies" / "photos" / "ab.jpg"
    with Image.open(out) as im:
        assert im.size == (1600, 1067)
    with Image.open(tmp_path / "db" / "proxies" / "faces" / "7.jpg") as im:
        assert im.size == (240, 240)
    src.unlink()
    db_row = sqlite3.connect(db)
    db_row.execute("UPDATE images SET availability='archived'")
    db_row.commit()
    assert proxies.build_proxies(db, [1])["built"] == [1]


def test_exif_orientation_6_rotates(tmp_path):
    src = tmp_path / "r.jpg"
    jpeg(src, (400, 200), orientation=6)
    db = make_db(tmp_path, [(1, str(src), "r", "present", 400, 200, 6)])
    proxies.build_proxies(db, [1])
    with Image.open(tmp_path / "db" / "proxies" / "photos" / "r.jpg") as im:
        assert im.size == (200, 400)


def test_failed_when_missing_and_no_proxy(tmp_path):
    db = make_db(tmp_path, [(1, str(tmp_path / "no.jpg"), "n", "missing", 1, 1, 1)])
    result = proxies.build_proxies(db, [1, 99])
    assert result["built"] == []
    assert [f["image_id"] for f in result["failed"]] == [1, 99]
    assert not list((tmp_path / "db").rglob("*.tmp"))


def test_image_source(tmp_path):
    src = tmp_path / "x.jpg"
    jpeg(src, (50, 50))
    db = make_db(tmp_path, [])
    row = {"path": str(src), "sha256": "ab", "availability": "present"}
    assert proxies.image_source(db, row) == src
    gone = {"path": str(tmp_path / "g.jpg"), "sha256": "ab", "availability": "archived"}
    assert proxies.image_source(db, gone) is None
    proxy = tmp_path / "db" / "proxies" / "photos" / "ab.jpg"
    jpeg(proxy, (10, 10))
    assert proxies.image_source(db, gone) == proxy


def test_face_thumbnail_from_proxy_scaled(tmp_path):
    src = tmp_path / "f.jpg"
    big = Image.new("RGB", (2000, 1000), (0, 0, 255))
    big.paste((255, 0, 0), (1000, 400, 1400, 800))
    big.save(src)
    db = make_db(tmp_path, [(1, str(src), "f", "present", 2000, 1000, 1)], [(3, 1, 1000, 400, 400, 400)])
    proxies.build_proxies(db, [1])
    (tmp_path / "db" / "proxies" / "faces" / "3.jpg").unlink()
    src.unlink()
    c = sqlite3.connect(db)
    c.execute("UPDATE images SET availability='archived'")
    c.commit()
    data = proxies.face_thumbnail(db, 3)
    with Image.open(BytesIO(data)) as im:
        assert im.size == (240, 240)
        r, _g, b = im.convert("RGB").getpixel((120, 120))
        assert r > 200 and b < 60


def test_face_thumbnail_unknown(tmp_path):
    db = make_db(tmp_path, [])
    try:
        proxies.face_thumbnail(db, 1)
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_image_source_accepts_sqlite_row(tmp_path):
    src = tmp_path / "r.jpg"
    jpeg(src, (50, 50))
    db = make_db(tmp_path, [])
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    row = connection.execute("SELECT ? AS path, 'ab' AS sha256, 'present' AS availability", (str(src),)).fetchone()
    assert proxies.image_source(db, row) == src


def test_oversized_image_gets_proxy_and_limit_restored(tmp_path, monkeypatch):
    src = tmp_path / "huge.jpg"
    jpeg(src, (3000, 2000))
    db = make_db(tmp_path, [(1, str(src), "hg", "present", 3000, 2000, 1)], [(7, 1, 100, 100, 200, 200)])
    # 6 MP source is over 2x this limit (bomb error); the 1.7 MP proxy stays under it
    monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 2_500_000)
    result = proxies.build_proxies(db, [1])
    assert result == {"built": [1], "failed": []}
    assert Image.MAX_IMAGE_PIXELS == 2_500_000
    with Image.open(tmp_path / "db" / "proxies" / "photos" / "hg.jpg") as im:
        assert im.size == (1600, 1067)
    assert (tmp_path / "db" / "proxies" / "faces" / "7.jpg").is_file()


def test_limit_restored_when_open_fails(tmp_path, monkeypatch):
    bad = tmp_path / "bad.jpg"
    bad.write_bytes(b"not an image")
    monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 1234)
    try:
        proxies._load_rgb(bad)
    except OSError:
        pass
    assert Image.MAX_IMAGE_PIXELS == 1234


def test_build_proxies_reports_progress(tmp_path):
    src = tmp_path / "p.jpg"
    jpeg(src, (200, 100))
    db = make_db(tmp_path, [(1, str(src), "p", "present", 200, 100, 1)])
    seen = []
    proxies.build_proxies(db, [1, 99], lambda current, total: seen.append((current, total)))
    assert seen == [(1, 2), (2, 2)]


def test_face_thumbnail_without_source_is_none(tmp_path):
    db = make_db(
        tmp_path,
        [(1, str(tmp_path / "gone.jpg"), "gn", "missing", 100, 100, 1)],
        [(4, 1, 10, 10, 20, 20)],
    )
    assert proxies.face_thumbnail(db, 4) is None


def test_face_thumbnail_from_original_writes_face_proxy(tmp_path):
    src = tmp_path / "o.jpg"
    jpeg(src, (400, 300))
    db = make_db(tmp_path, [(1, str(src), "or", "present", 400, 300, 1)], [(5, 1, 100, 100, 100, 100)])
    data = proxies.face_thumbnail(db, 5)
    cached = tmp_path / "db" / "proxies" / "faces" / "5.jpg"
    assert cached.read_bytes() == data
    assert not list((tmp_path / "db").rglob("*.tmp"))
