from __future__ import annotations

import sys
import types
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from ailbum.models import PipelineConfig
from ailbum.pipeline import analyze_library
from ailbum.ranking.select import Candidate, select_for_target

BASE = [
    Candidate(1, 0.9, 1, None, None),
    Candidate(2, 0.8, 1, None, None),
    Candidate(3, 0.5, 2, None, None),
]


def test_plan_examples():
    assert select_for_target(BASE, 2, []) == [1, 3]
    assert select_for_target(BASE, 2, [2]) == [2, 3]


def test_keep_all_even_over_target_and_unknown():
    assert select_for_target(BASE, 1, [2, 99]) == [2, 99]


def test_exhausted_candidates():
    assert select_for_target(BASE, 10, []) == [1, 3, 2]


def test_embedding_penalty():
    a = Candidate(1, 0.9, None, None, np.array([1.0, 0.0]))
    b = Candidate(2, 0.8, None, None, np.array([1.0, 0.0]))
    c = Candidate(3, 0.6, None, None, np.array([0.0, 1.0]))
    assert select_for_target([a, b, c], 2, []) == [1, 3]


def test_similar_cluster_not_twice_while_others_remain():
    cands = [
        Candidate(1, 0.9, None, 7, None),
        Candidate(2, 0.8, None, 7, None),
        Candidate(3, 0.1, None, None, None),
    ]
    assert select_for_target(cands, 2, []) == [1, 3]
    assert select_for_target(cands, 3, []) == [1, 3, 2]


def test_ties_by_image_id():
    cands = [Candidate(5, 0.5, None, None, None), Candidate(4, 0.5, None, None, None)]
    assert select_for_target(cands, 1, []) == [4]


def _pair(source: Path) -> None:
    source.mkdir()
    detailed = np.zeros((320, 320, 3), dtype=np.uint8)
    for index in range(20, 300, 20):
        cv2.line(detailed, (index, 10), (index, 310), (255, 200, 20), 3)
    softer = cv2.GaussianBlur(detailed, (9, 9), 2)
    for name, arr in (("a.jpg", detailed), ("b.jpg", softer)):
        Image.fromarray(cv2.cvtColor(arr, cv2.COLOR_BGR2RGB)).save(source / name)


def _run(tmp_path: Path, database: Path | None) -> dict:
    source = tmp_path / "photos"
    _pair(source)
    return analyze_library(
        source,
        tmp_path / "result",
        PipelineConfig(
            sharpness_threshold=0, photo_hash_distance=16, photo_hist_similarity=0.5,
            face_backend="classic", semantic_backend="off", story_naming_backend="rules",
            models_dir=tmp_path / "models",
        ),
        database=database,
    )


def test_pipeline_without_model_records_quality(tmp_path: Path) -> None:
    manifest = _run(tmp_path, tmp_path / "c.sqlite3")
    assert manifest["selection_model"] == "quality"
    assert [p["selected"] for p in manifest["photos"]] == [True, False]


def test_pipeline_with_fake_model_picks_by_score(tmp_path: Path, monkeypatch) -> None:
    class Fake:
        id = 7

        def score(self, x):
            return -x[:, 0]  # prefers lowest quality

    from ailbum import ranking

    fake_store = types.ModuleType("ailbum.ranking.store")
    fake_store.active_model = lambda connection, kind: Fake()
    monkeypatch.setitem(sys.modules, "ailbum.ranking.store", fake_store)
    monkeypatch.setattr(ranking, "store", fake_store, raising=False)
    manifest = _run(tmp_path, tmp_path / "c.sqlite3")
    assert manifest["selection_model"] == "pairwise:7"
    assert [p["selected"] for p in manifest["photos"]] == [False, True]
