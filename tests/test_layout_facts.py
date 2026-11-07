from __future__ import annotations

import json
import sqlite3
from dataclasses import astuple
from pathlib import Path

import pytest
from PIL import Image

from ailbum.cv.objects import DETECTOR_MODEL, DetectedObject
from ailbum.database import connect
from ailbum.layout.facts import PhotoFacts, build_regions, load_pool
from ailbum.layout.types import Rect


class FakeDetector:
    def __init__(self, objects: list[DetectedObject] | None = None) -> None:
        self.objects = objects or []
        self.calls = 0

    def detect(self, image):
        assert image.ndim == 3 and image.shape[2] == 3
        self.calls += 1
        return list(self.objects)


@pytest.fixture
def conn(tmp_path: Path):
    with connect(tmp_path / "db.sqlite") as connection:
        connection.execute(
            "INSERT INTO analysis_runs VALUES ('r','s','o','t','t','dnn','{}','{}','completed')"
        )
        connection.execute(
            "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
            " VALUES (1, 'u1', 'А', 'r', 't', 't')"
        )
        yield connection


def add_image(
    conn: sqlite3.Connection,
    image_id: int,
    *,
    selected: bool = True,
    cluster: int | None = None,
    blurry: bool = False,
    width: int = 40,
    height: int = 30,
    orientation: int | None = None,
    exists: bool = True,
    quality: float = 0.5,
    aesthetic: float | None = None,
    subject: tuple[float, float, float, float] | None = None,
    story_id: int | None = None,
    sha: str = "sha",
) -> Path:
    path = Path(conn.execute("PRAGMA database_list").fetchone()[2]).parent / f"{image_id}.jpg"
    if exists:
        Image.new("RGB", (40, 30), (10, 20, 30)).save(path)
    conn.execute(
        """INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
        file_size_bytes, modified_at, sha256, width, height, orientation, taken_at,
        exif_json, container_metadata_json, indexed_at)
        VALUES (?, ?, 's', ?, ?, '.jpg', 1, 't', ?, ?, ?, ?, ?, '{}', '{}', 't')""",
        (image_id, str(path), path.name, path.name, sha, width, height, orientation,
         f"2026-01-01T10:00:{image_id:02d}"),
    )
    conn.execute(
        """INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,
        aesthetic_score, main_subject_json, is_blurry, similar_cluster, story_id, selected)
        VALUES ('r', ?, ?, 1, 1, ?, ?, ?, ?, ?, ?, 0)""",
        (image_id, f"p{image_id}", quality, aesthetic,
         json.dumps({"bbox": list(subject), "center": [0, 0], "source": "x"}) if subject else None,
         int(blurry), cluster, story_id),
    )
    if selected:
        conn.execute(
            "INSERT INTO album_photos VALUES (1, ?, ?, 't')", (image_id, image_id)
        )
    return path


def add_face(conn, image_id, bbox, *, closed=False, smile=None, index=0):
    conn.execute(
        """INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y, bbox_width,
        bbox_height, confidence, both_eyes_open, smile_probability)
        VALUES ('r', ?, ?, ?, ?, ?, ?, ?, 0.9, ?, ?)""",
        (image_id, f"f{image_id}-{index}", index, *bbox, 0 if closed else 1, smile),
    )


def test_build_regions_face_expansion():
    regions = build_regions([(0.4, 0.4, 0.1, 0.1)], [], None)
    assert len(regions) == 1
    assert regions[0].hard and regions[0].weight == 1.0
    b = regions[0].bbox
    assert (b.x, b.y, b.w, b.h) == pytest.approx((0.38, 0.365, 0.14, 0.15))


def test_background_face_is_soft():
    regions = build_regions([(0.1, 0.1, 0.5, 0.5), (0.8, 0.8, 0.05, 0.05)], [], None)
    assert regions[0].hard
    assert not regions[1].hard and regions[1].weight == 0.2
    assert astuple(regions[1].bbox) == pytest.approx((0.8, 0.8, 0.05, 0.05))


def test_expanded_face_clipped_to_image():
    b = build_regions([(0.0, 0.0, 0.2, 0.2)], [], None)[0].bbox
    assert b.x == 0.0 and b.y == 0.0


def test_objects_weights_and_threshold():
    objects = [
        DetectedObject("person", 0.4, (0.1, 0.1, 0.2, 0.5)),
        DetectedObject("dog", 0.6, (0.5, 0.5, 0.2, 0.2)),
        DetectedObject("cup", 0.4, (0.7, 0.7, 0.1, 0.1)),
    ]
    regions = build_regions([], objects, None)
    assert [(r.kind, r.weight, r.hard) for r in regions] == [
        ("person", 0.6, False),
        ("object", 0.5, False),
    ]


def test_zero_area_region_ignored():
    assert build_regions([(0.1, 0.1, 0.0, 0.2)], [DetectedObject("dog", 0.9, (0, 0, 0, 0.1))],
                         Rect(0.1, 0.1, 0.0, 0.0)) == ()


def test_saliency_only_without_faces_and_objects():
    subject = Rect(0.2, 0.2, 0.3, 0.3)
    only = build_regions([], [], subject)
    assert [(r.kind, r.weight, r.hard) for r in only] == [("subject", 0.3, False)]
    assert all(r.kind != "subject" for r in build_regions([(0.4, 0.4, 0.1, 0.1)], [], subject))
    weak = [DetectedObject("cup", 0.3, (0.1, 0.1, 0.1, 0.1))]
    assert build_regions([], weak, subject)[0].kind == "subject"


def test_rotated_exif_swaps_aspect(conn):
    add_image(conn, 1, width=4000, height=3000, orientation=6)
    add_image(conn, 2, width=4000, height=3000, orientation=1)
    pool = {p.image_id: p for p in load_pool(conn, 1, None)}
    assert pool[1].aspect == pytest.approx(0.75)
    assert pool[2].aspect == pytest.approx(4 / 3)


def test_face_normalized_by_rotated_size(conn):
    add_image(conn, 1, width=4000, height=3000, orientation=6)
    add_face(conn, 1, (300, 600, 300, 300))
    region = load_pool(conn, 1, None)[0].regions[0]
    # rotated frame is 3000 wide, 4000 high; raw bbox x=0.1, y=0.15, w=0.1, h=0.075
    assert region.bbox.x == pytest.approx(0.1 - 0.1 * 0.2)
    assert region.bbox.y == pytest.approx(0.15 - 0.075 * 0.35)
    assert region.bbox.w == pytest.approx(0.14)


def test_missing_file_excluded(conn):
    add_image(conn, 1, exists=False)
    add_image(conn, 2)
    assert [p.image_id for p in load_pool(conn, 1, None)] == [2]


def test_unit_keys_and_story(conn):
    add_image(conn, 1, cluster=3, story_id=7)
    add_image(conn, 2)
    pool = {p.image_id: p for p in load_pool(conn, 1, None)}
    assert pool[1].unit_key == "cluster:3" and pool[1].story_id == 7
    assert pool[1].taken_at == "2026-01-01T10:00:01"
    assert pool[2].unit_key == "image:2" and pool[2].story_id is None
    assert isinstance(pool[1], PhotoFacts) and pool[1].selected


def test_unselected_sibling_in_pool(conn):
    add_image(conn, 1, cluster=3)
    add_image(conn, 2, cluster=3, selected=False)
    pool = {p.image_id: p for p in load_pool(conn, 1, None)}
    assert set(pool) == {1, 2}
    assert not pool[2].selected


def test_blurry_sibling_excluded(conn):
    add_image(conn, 1, cluster=3)
    add_image(conn, 2, cluster=3, selected=False, blurry=True)
    assert [p.image_id for p in load_pool(conn, 1, None)] == [1]


def test_unrelated_unselected_excluded(conn):
    add_image(conn, 1, cluster=3)
    add_image(conn, 2, cluster=4, selected=False)
    add_image(conn, 3, cluster=None, selected=False)
    assert [p.image_id for p in load_pool(conn, 1, None)] == [1]


def test_rank_penalises_closed_eyes(conn):
    add_image(conn, 1, quality=0.6, aesthetic=0.4, selected=False, cluster=1)
    add_image(conn, 2, quality=0.6, aesthetic=0.4, selected=True, cluster=1)
    add_image(conn, 3, quality=0.6, aesthetic=0.4, selected=True)
    add_face(conn, 3, (1, 1, 5, 5), closed=True, smile=0.9)
    add_image(conn, 4, quality=0.6, aesthetic=0.4, selected=True)
    add_face(conn, 4, (1, 1, 5, 5), smile=0.9)
    pool = {p.image_id: p for p in load_pool(conn, 1, None)}
    base = 0.45 * 0.6 + 0.35 * 0.4
    assert pool[1].rank == pytest.approx(base)
    assert pool[2].rank == pytest.approx(base + 0.2)
    assert pool[4].rank == pytest.approx(base + 0.1 + 0.2)
    assert pool[3].rank == pytest.approx(base + 0.1)
    assert pool[3].rank < pool[4].rank


def test_rank_clamped(conn):
    add_image(conn, 1, quality=1.0, aesthetic=1.0)
    add_face(conn, 1, (1, 1, 5, 5), smile=1.0)
    assert load_pool(conn, 1, None)[0].rank == 1.0


def test_saliency_used_from_database(conn):
    add_image(conn, 1, subject=(0.2, 0.2, 0.3, 0.3))
    region = load_pool(conn, 1, None)[0].regions[0]
    assert region.kind == "subject" and region.bbox == Rect(0.2, 0.2, 0.3, 0.3)


def test_detector_results_cached(conn):
    add_image(conn, 1)
    detector = FakeDetector([DetectedObject("dog", 0.8, (0.1, 0.1, 0.4, 0.4))])
    first = load_pool(conn, 1, detector)
    assert detector.calls == 1
    assert first[0].regions[0].kind == "object"
    again = load_pool(conn, 1, detector)
    assert detector.calls == 1
    assert again[0].regions == first[0].regions
    # no detector: cached scan is still read
    assert load_pool(conn, 1, None)[0].regions == first[0].regions
    row = conn.execute("SELECT detector_model FROM image_object_scans").fetchone()
    assert row[0] == DETECTOR_MODEL


def test_cached_scan_not_rerun_with_progress(conn):
    add_image(conn, 1)
    add_image(conn, 2)
    detector = FakeDetector()
    seen: list[tuple[int, int]] = []
    load_pool(conn, 1, detector, lambda done, total: seen.append((done, total)))
    assert detector.calls == 2
    assert seen[-1] == (2, 2)


def test_scan_rerun_when_sha_changes(conn):
    add_image(conn, 1)
    detector = FakeDetector()
    load_pool(conn, 1, detector)
    conn.execute("UPDATE images SET sha256 = 'other' WHERE id = 1")
    load_pool(conn, 1, detector)
    assert detector.calls == 2
    assert conn.execute("SELECT sha256 FROM image_object_scans").fetchone()[0] == "other"


def test_stale_scan_ignored_without_detector(conn):
    add_image(conn, 1)
    load_pool(conn, 1, FakeDetector([DetectedObject("dog", 0.8, (0.1, 0.1, 0.4, 0.4))]))
    conn.execute("UPDATE images SET sha256 = 'other' WHERE id = 1")
    assert load_pool(conn, 1, None)[0].regions == ()


def test_unreadable_image_does_not_abort(conn):
    path = add_image(conn, 1)
    path.write_bytes(b"not an image")
    add_image(conn, 2)
    detector = FakeDetector()
    pool = load_pool(conn, 1, detector)
    assert [p.image_id for p in pool] == [1, 2]
    assert detector.calls == 1


def test_archived_uses_proxy_and_skips_detector(conn):
    path = add_image(conn, 1, exists=False, sha="abc")
    conn.execute("UPDATE images SET availability = 'archived' WHERE id = 1")
    detector = FakeDetector([DetectedObject("dog", 0.8, (0.1, 0.1, 0.4, 0.4))])
    assert load_pool(conn, 1, detector) == []
    proxy = path.parent / "proxies" / "photos" / "abc.jpg"
    proxy.parent.mkdir(parents=True)
    Image.new("RGB", (40, 30)).save(proxy)
    pool = load_pool(conn, 1, detector)
    assert [p.image_id for p in pool] == [1]
    assert detector.calls == 0


def test_album_without_run_raises(conn):
    conn.execute("UPDATE albums SET run_id = NULL")
    with pytest.raises(ValueError, match="У альбома нет анализа"):
        load_pool(conn, 1, None)
