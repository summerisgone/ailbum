from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ailbum import database
from ailbum.ranking import features, store, train
from ailbum.ranking.labels import group_pairs
from ailbum.ranking.model import LogisticModel


@pytest.fixture
def conn(tmp_path: Path):
    path = tmp_path / "db.sqlite3"
    with database.connect(path) as c:
        yield c


class Seeder:
    def __init__(self, c):
        self.c = c
        self.next_image = 1

    def image(self, sha=None):
        i = self.next_image
        self.next_image += 1
        self.c.execute(
            "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (i, f"/p/{i}.jpg", "/p", f"{i}.jpg", f"{i}.jpg", ".jpg", 1, "t", sha or f"sha{i}", "{}", "{}", "t"),
        )
        return i

    def album(self, n, groups, eyes_pick=True, events=True, shas=None, quality_pick=False):
        """groups: n groups of 2 photos; photo A higher quality, B has eyes open (B picked)."""
        run = f"run{n}"
        self.c.execute(
            "INSERT INTO analysis_runs VALUES (?,?,?,?,?,?,?,?,?)",
            (run, "/p", "/o", "t", "t", "classic", "{}", "{}", "completed"),
        )
        self.c.execute(
            "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
            " VALUES (?,?,?,?,?,?)", (n, f"pub{n}", f"a{n}", run, "t", "t"),
        )
        for g in range(groups):
            a = self.image(shas[2 * g] if shas else None)
            b = self.image(shas[2 * g + 1] if shas else None)
            for image_id, q, in ((a, 0.9), (b, 0.5)):
                self.c.execute(
                    "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,"
                    " is_blurry, similar_cluster, selected) VALUES (?,?,?,?,?,?,0,?,0)",
                    (run, image_id, f"p{image_id}", 1.0, 1.0, q, g + 1),
                )
                self.c.execute(
                    "INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
                    " bbox_width, bbox_height, confidence, left_eye_state, right_eye_state)"
                    " VALUES (?,?,?,?,0,0,5,5,0.9,?,?)",
                    (run, image_id, f"f{image_id}", 0,
                     "open" if image_id == b else "closed", "open"),
                )
            pick = a if quality_pick else b
            self.c.execute(
                "INSERT INTO album_photos VALUES (?,?,?,?)", (n, pick, g, "t")
            )
            if events:
                self.c.execute(
                    "INSERT INTO selection_events (album_id, run_id, image_id, action, source, created_at)"
                    " VALUES (?,?,?,?,?,?)", (n, run, pick, "add", "manual", "t"),
                )
        return run


def test_group_pairs_only_touched():
    groups = {1: [1, 2], 2: [3, 4]}
    events = [{"image_id": 2, "source": "manual", "action": "add"},
              {"image_id": 3, "source": "auto", "action": "seed"}]
    assert group_pairs(events, {2, 3}, groups) == [(2, 1)]


def test_status_not_enough(conn):
    Seeder(conn).album(1, 3)
    st = train.status(conn)
    assert st["pairs"] == 3 and st["albums"] == 1
    assert st["pairwise"] is None and st["pointwise"] is None
    assert st["reason"] == "нужно не меньше 50 пар из 2 альбомов"
    assert train.train(conn)["pairwise"] is None


def test_eyes_open_ranker_beats_quality(conn):
    s = Seeder(conn)
    s.album(1, 30)
    s.album(2, 30)
    out = train.train(conn)
    assert out["pairwise"]["active"] is True
    assert out["pairwise"]["accuracy"] == 1.0 and out["pairwise"]["baseline"] == 0.0
    model = store.active_model(conn, "pairwise")
    assert model.id == out["pairwise"]["id"]
    # Fresh pair: A has higher quality, B has eyes open.
    run = s.album(3, 1, events=False)
    vec = features.from_rows(conn, run)
    scores = model.score(np.array([vec[s.next_image - 2], vec[s.next_image - 1]]))
    assert scores[1] > scores[0]
    assert vec[s.next_image - 2][features.FEATURE_NAMES.index("quality")] > 0.5


def test_not_activated_when_worse_than_baseline(conn):
    s = Seeder(conn)
    s.album(1, 30)  # picks eyes-open lower quality
    s.album(2, 30, quality_pick=True)  # picks quality: conflicting labels
    out = train.evaluate(conn)
    p = out["pairwise"]
    assert p["active"] == (p["accuracy"] >= p["baseline"])
    assert store.active_model(conn, "pairwise") is None  # evaluate does not save


def test_sha_duplicates_share_one_fold(conn):
    s = Seeder(conn)
    shas = [f"s{i}" for i in range(60)]
    s.album(1, 30, shas=shas)
    s.album(2, 30, shas=shas)
    out = train.evaluate(conn)
    assert out["pairwise"]["accuracy"] is None  # one connected fold: no honest evaluation
    assert out["pairwise"]["active"] is False


def test_pointwise_needs_five_events(conn):
    s = Seeder(conn)
    s.album(1, 6)
    s.album(2, 3)
    out = train.evaluate(conn)
    assert out["pointwise"] is None
    s.album(3, 6)
    out = train.evaluate(conn)
    assert out["pointwise"]["albums"] == 2


def test_stale_feature_version_ignored(conn):
    m = LogisticModel.fit(np.array([[0.0], [1.0], [2.0], [3.0]]), np.array([0, 0, 1, 1]))
    m.feature_version = features.FEATURE_VERSION + 1
    store.save_model(conn, "pairwise", m, {}, True)
    assert store.active_model(conn, "pairwise") is None
    good = LogisticModel.fit(np.array([[0.0], [1.0], [2.0], [3.0]]), np.array([0, 0, 1, 1]))
    store.save_model(conn, "pairwise", good, {}, True)
    assert store.active_model(conn, "pairwise") is not None
    new_id = store.save_model(conn, "pairwise", good, {}, True)
    assert store.active_model(conn, "pairwise").id == new_id
    assert conn.execute("SELECT COUNT(*) FROM ranking_models WHERE active = 1").fetchone()[0] == 1
