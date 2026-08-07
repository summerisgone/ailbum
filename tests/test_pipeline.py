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

    manifest = analyze_library(
        source,
        output,
        PipelineConfig(
            sharpness_threshold=0,
            photo_hash_distance=16,
            photo_hist_similarity=0.5,
            face_backend="classic",
            models_dir=tmp_path / "models",
        ),
        database=database,
    )

    assert manifest["summary"]["photos"] == 2  # type: ignore[index]
    assert manifest["summary"]["selected"] == 1  # type: ignore[index]
    photos = manifest["photos"]
    assert photos[0]["selected"] is True  # type: ignore[index]
    assert photos[1]["selected"] is False  # type: ignore[index]
    assert (output / "selection.csv").exists()
    on_disk = json.loads((output / "analysis.json").read_text(encoding="utf-8"))
    assert on_disk["schema_version"] == 2
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT COUNT(*) FROM images").fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM analysis_runs").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM photo_analysis").fetchone()[0] == 2
