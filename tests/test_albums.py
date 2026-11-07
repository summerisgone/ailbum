import pytest

from ailbum import albums
from ailbum.database import connect


@pytest.fixture
def conn(tmp_path):
    with connect(tmp_path / "a.sqlite") as c:
        c.execute(
            "INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','x','{}','{}','completed')"
        )
        c.execute(
            "INSERT INTO analysis_runs VALUES ('r2','/p','/o','t','t','x','{}','{}','completed')"
        )
        yield c


def add_image(c, n=1):
    c.execute(
        "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
        " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
        " VALUES (?, ?, '/p', 'a', 'a', 'jpg', 1, 't', 's', '{}', '{}', 't')",
        (n, f"/p/{n}.jpg"),
    )


def test_create_get(conn):
    i = albums.create_album(conn, "Турция", ["/p", "/p"], "r1")
    a = albums.get_album(conn, i)
    assert a["sources"] == ["/p"] and a["status"] == "draft" and a["photo_count"] == 0
    assert a["target_count"] == 24 and a["run_id"] == "r1"
    with pytest.raises(ValueError, match="не найден"):
        albums.get_album(conn, 99)


def test_transitions(conn):
    i = albums.create_album(conn, "t", ["/p"])
    assert albums.set_status(conn, i, "draft")["status"] == "draft"
    a = albums.set_status(conn, i, "ordered")
    assert a["ordered_at"]
    assert albums.set_status(conn, i, "draft")["ordered_at"] is None
    with pytest.raises(ValueError):
        albums.set_status(conn, i, "archived")
    albums.set_status(conn, i, "ordered")
    assert albums.set_status(conn, i, "archived")["archived_at"]
    for target in ("draft", "ordered"):
        with pytest.raises(ValueError):
            albums.set_status(conn, i, target)


def test_delete_archived_requires_flag(conn):
    i = albums.create_album(conn, "t", ["/p"])
    albums.set_status(conn, i, "ordered")
    with pytest.raises(ValueError, match="forget_decisions"):
        albums.delete_album(conn, i)
    albums.delete_album(conn, i, forget_decisions=True)
    assert albums.list_albums(conn) == []


def test_delete_keeps_images(conn):
    add_image(conn)
    i = albums.create_album(conn, "t", ["/p"])
    conn.execute("INSERT INTO album_photos VALUES (?, 1, 0, 't')", (i,))
    albums.delete_album(conn, i)
    assert conn.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM album_sources").fetchone()[0] == 0
    assert conn.execute("SELECT COUNT(*) FROM album_photos").fetchone()[0] == 0


def test_require_draft(conn):
    i = albums.create_album(conn, "t", ["/p"])
    albums.require_draft(conn, i)
    albums.set_status(conn, i, "ordered")
    with pytest.raises(ValueError, match="Альбом заказан"):
        albums.require_draft(conn, i)


def test_attach_run(conn):
    i = albums.create_album(conn, "t", ["/p"], "r1")
    assert albums.attach_run(conn, "r2", ["/p"]) == i
    assert albums.get_album(conn, i)["run_id"] == "r2"
    albums.set_status(conn, i, "ordered")
    j = albums.attach_run(conn, "r1", ["/p"])
    assert j != i
    a = albums.get_album(conn, j)
    assert a["title"] == "p" and a["run_id"] == "r1"
    assert albums.get_album(conn, i)["run_id"] == "r2"


def test_list_order_and_rename(conn):
    a = albums.create_album(conn, "a", ["/a"])
    b = albums.create_album(conn, "b", ["/b"])
    albums.set_status(conn, a, "ordered")
    assert [x["id"] for x in albums.list_albums(conn)] == [b, a]
    assert albums.rename_album(conn, b, "  Новое ")["title"] == "Новое"
    with pytest.raises(ValueError):
        albums.rename_album(conn, b, "  ")
