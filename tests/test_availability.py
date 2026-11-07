from pathlib import Path

from ailbum.database import (
    connect,
    database_summary,
    index_metadata,
    mark_source_missing,
)
from ailbum.metadata import ImageMetadata


def _meta(root: Path, name: str, sha: str) -> ImageMetadata:
    return ImageMetadata(
        path=str(root / name), source_root=str(root), relative_path=name, file_name=name,
        extension=".jpg", file_size_bytes=1, modified_at="t", created_at=None, sha256=sha,
        mime_type=None, image_format=None, color_mode=None, width=1, height=1,
        frame_count=1, orientation=None, taken_at=None, camera_make=None, camera_model=None,
        lens_model=None, software=None, gps_latitude=None, gps_longitude=None,
        gps_altitude=None, exif={}, container_metadata={}, extraction_error=None,
    )


def _state(db: Path) -> list[tuple]:
    with connect(db) as c:
        return [tuple(r) for r in c.execute("SELECT id, path, availability FROM images ORDER BY id")]


def test_present_to_missing(tmp_path: Path) -> None:
    db = tmp_path / "d.sqlite3"
    root = tmp_path / "a"
    root.mkdir()
    index_metadata(db, root, [_meta(root, "1.jpg", "s1"), _meta(root, "2.jpg", "s2")])
    index_metadata(db, root, [_meta(root, "1.jpg", "s1")])
    assert [r[2] for r in _state(db)] == ["present", "missing"]
    index_metadata(db, root, [_meta(root, "1.jpg", "s1"), _meta(root, "2.jpg", "s2")])
    assert [r[2] for r in _state(db)] == ["present", "present"]


def test_index_never_touches_archived(tmp_path: Path) -> None:
    db = tmp_path / "d.sqlite3"
    root = tmp_path / "a"
    root.mkdir()
    index_metadata(db, root, [_meta(root, "1.jpg", "s1")])
    with connect(db) as c:
        c.execute("UPDATE images SET availability = 'archived'")
        mark_source_missing(c, str(root))
    assert _state(db)[0][2] == "archived"
    index_metadata(db, root, [])
    assert _state(db)[0][2] == "archived"


def test_sha_match_relinks_single(tmp_path: Path) -> None:
    db = tmp_path / "d.sqlite3"
    a, b = tmp_path / "a", tmp_path / "b"
    index_metadata(db, a, [_meta(a, "1.jpg", "X")])
    with connect(db) as c:
        c.execute("UPDATE images SET availability = 'archived'")
    index_metadata(db, b, [_meta(b, "1.jpg", "X")])
    assert _state(db) == [(1, str(b / "1.jpg"), "present")]


def test_sha_two_matches_new_row(tmp_path: Path) -> None:
    db = tmp_path / "d.sqlite3"
    a, b = tmp_path / "a", tmp_path / "b"
    index_metadata(db, a, [_meta(a, "1.jpg", "X"), _meta(a, "2.jpg", "X")])
    with connect(db) as c:
        c.execute("UPDATE images SET availability = 'archived'")
    index_metadata(db, b, [_meta(b, "3.jpg", "X")])
    assert len(_state(db)) == 3
    assert _state(db)[2][1:] == (str(b / "3.jpg"), "present")


def test_summary_counts_availability(tmp_path: Path) -> None:
    db = tmp_path / "d.sqlite3"
    root = tmp_path / "a"
    index_metadata(db, root, [_meta(root, f"{i}.jpg", f"s{i}") for i in range(3)])
    with connect(db) as c:
        c.execute("UPDATE images SET availability = 'archived' WHERE id = 1")
        c.execute("UPDATE images SET availability = 'missing' WHERE id = 2")
    assert database_summary(db)["availability"] == {"present": 1, "missing": 1, "archived": 1}
