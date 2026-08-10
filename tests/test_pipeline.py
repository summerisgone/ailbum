import json
import sqlite3
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from ailbum.models import PipelineConfig
from ailbum.pipeline import analyze_library


def _write_rgb(path: Path, array: np.ndarray) -> None:
    Image.fromarray(cv2.cvtColor(array, cv2.COLOR_BGR2RGB)).save(path)


def test_pipeline_writes_manifest_and_selects_best_of_duplicates(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    output = tmp_path / "result"
    database = tmp_path / "catalog.sqlite3"
    source.mkdir()
    detailed = np.zeros((320, 320, 3), dtype=np.uint8)
    for index in range(20, 300, 20):
        cv2.line(detailed, (index, 10), (index, 310), (255, 200, 20), 3)
    softer = cv2.GaussianBlur(detailed, (9, 9), 2)
    _write_rgb(source / "a.jpg", detailed)
    _write_rgb(source / "b.jpg", softer)
    progress: list[str] = []

    manifest = analyze_library(
        source,
        output,
        PipelineConfig(
            sharpness_threshold=0,
            photo_hash_distance=16,
            photo_hist_similarity=0.5,
            face_backend="classic",
            semantic_backend="off",
            story_naming_backend="rules",
            models_dir=tmp_path / "models",
        ),
        progress=progress.append,
        database=database,
    )

    assert manifest["summary"]["photos"] == 2  # type: ignore[index]
    assert manifest["summary"]["selected"] == 1  # type: ignore[index]
    assert any(item.startswith("Этап: Анализ фотографий|") for item in progress)
    assert any(item.startswith("Этап: Поиск похожих кадров|") for item in progress)
    assert any(item.startswith("Этап: Сохранение|") for item in progress)
    photos = manifest["photos"]
    assert photos[0]["selected"] is True  # type: ignore[index]
    assert photos[1]["selected"] is False  # type: ignore[index]
    assert (output / "selection.csv").exists()
    on_disk = json.loads((output / "analysis.json").read_text(encoding="utf-8"))
    assert on_disk["schema_version"] == 6
    assert on_disk["summary"]["stories"] == 1
    assert on_disk["story_groups"][0]["photo_ids"] == ["photo-00001", "photo-00002"]
    assert on_disk["photos"][0]["story_id"] == 1
    assert on_disk["photos"][0]["composition"]["rule_of_thirds"] is not None
    assert on_disk["photos"][0]["color"]["harmony"] is not None
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM analysis_runs").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM photo_analysis").fetchone()[0] == 2
        columns = {row[1] for row in connection.execute("PRAGMA table_info(photo_analysis)")}
        assert {"aesthetic_score", "rule_of_thirds", "scene_tags_json", "story_id"} <= columns
        assert connection.execute("SELECT COUNT(*) FROM stories").fetchone()[0] == 1


def test_pipeline_reuses_feature_cache_by_content_hash(tmp_path: Path) -> None:
    source = tmp_path / "photos"
    source.mkdir()
    image = np.zeros((160, 200, 3), dtype=np.uint8)
    cv2.circle(image, (100, 80), 45, (20, 180, 240), -1)
    _write_rgb(source / "sample.jpg", image)
    config = PipelineConfig(
        face_backend="classic",
        semantic_backend="off",
        story_naming_backend="rules",
        models_dir=tmp_path / "models",
        feature_cache_dir=tmp_path / "feature-cache",
    )

    first = analyze_library(source, tmp_path / "first", config)
    second = analyze_library(source, tmp_path / "second", config)

    assert first["feature_cache"]["writes"] == 1  # type: ignore[index]
    assert first["feature_cache"]["hits"] == 0  # type: ignore[index]
    assert second["feature_cache"]["hits"] == 1  # type: ignore[index]
    assert second["summary"]["feature_cache_hits"] == 1  # type: ignore[index]
    assert second["photos"] == first["photos"]
