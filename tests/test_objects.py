from __future__ import annotations

import math

import numpy as np
import pytest

from ailbum.cv.objects import (
    COCO_LABELS,
    DETECTOR_MODEL,
    OBJECTS_FILENAME,
    DetectedObject,
    ObjectDetector,
    decode_detections,
    letterbox,
)
from ailbum.model_download import MODEL_SOURCES

SHA = "c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063"


def _output(rows: dict[int, tuple[float, ...]]) -> np.ndarray:
    out = np.zeros((1, 8400, 85), dtype=np.float32)
    out[0, :, 2:4] = -10.0
    for index, (x, y, w, h, obj, cls, score) in rows.items():
        out[0, index, :4] = (x, y, w, h)
        out[0, index, 4] = obj
        out[0, index, 5 + int(cls)] = score
    return out


def test_decode_single_cell():
    out = _output({0: (2.0, 2.0, math.log(4), math.log(4), 1.0, 0, 0.9)})
    found = decode_detections(out, scale=1.0, width=640, height=640)
    assert len(found) == 1
    assert found[0].label == "person"
    assert found[0].score == pytest.approx(0.9)
    x, y, w, h = found[0].bbox
    assert (x, y, w, h) == pytest.approx((0.0, 0.0, 0.05, 0.05))


def test_below_threshold_filtered():
    out = _output({0: (2.0, 2.0, 1.0, 1.0, 1.0, 0, 0.2)})
    assert decode_detections(out, 1.0, 640, 640) == []


def test_no_detections_returns_empty():
    assert decode_detections(_output({}), 1.0, 640, 480) == []


def test_decode_box_clipped_to_image():
    # centre at the top-left corner of the letterbox, so half the box is outside
    out = _output({0: (0.0, 0.0, math.log(8), math.log(8), 1.0, 16, 0.9)})
    found = decode_detections(out, 1.0, 640, 640)
    assert found[0].label == "dog"
    assert found[0].bbox == pytest.approx((0.0, 0.0, 0.05, 0.05))


def test_box_in_padding_is_dropped():
    # image is 640x320, so the lower half of the letterbox is padding
    out = _output({80 * 60 + 40: (0.0, 0.0, math.log(4), math.log(4), 1.0, 0, 0.9)})
    assert decode_detections(out, 1.0, 640, 320) == []


def test_letterbox_scale_maps_back_for_portrait():
    image = np.zeros((600, 300, 3), dtype=np.uint8)
    padded, scale = letterbox(image)
    assert padded.shape == (640, 640, 3)
    assert scale == pytest.approx(640 / 600)
    # box covering the whole resized content: x 0..320, y 0..640 in letterbox space
    out = _output(
        {40 * 80 + 20: (0.0, 0.0, math.log(40), math.log(80), 1.0, 0, 0.9)}
    )
    found = decode_detections(out, scale, 300, 600)
    assert found[0].bbox == pytest.approx((0.0, 0.0, 1.0, 1.0), abs=0.01)


def test_letterbox_pads_with_114():
    padded, _ = letterbox(np.zeros((100, 200, 3), dtype=np.uint8))
    assert padded[-1, -1].tolist() == [114, 114, 114]
    assert padded[0, 0].tolist() == [0, 0, 0]


def test_nms_removes_duplicates():
    row = (2.0, 2.0, math.log(4), math.log(4), 1.0, 2, 0.9)
    out = _output({0: row, 1: (1.0, 2.0, math.log(4), math.log(4), 1.0, 2, 0.8)})
    found = decode_detections(out, 1.0, 640, 640)
    assert [d.label for d in found] == ["car"]


def test_labels_and_constants():
    assert len(COCO_LABELS) == 80
    assert COCO_LABELS[0] == "person"
    assert DETECTOR_MODEL == "yolox_s_2022nov"
    assert OBJECTS_FILENAME == "object_detection_yolox_2022nov.onnx"
    assert DetectedObject("person", 0.9, (0.1, 0.2, 0.3, 0.6)).label == "person"


def test_model_listed_for_download():
    url, sha = MODEL_SOURCES[OBJECTS_FILENAME]
    assert sha == SHA
    assert url.endswith("object_detection_yolox/object_detection_yolox_2022nov.onnx")


def test_available(tmp_path):
    assert not ObjectDetector.available(tmp_path)
    (tmp_path / OBJECTS_FILENAME).write_bytes(b"x")
    assert ObjectDetector.available(tmp_path)


def test_missing_model_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        ObjectDetector(tmp_path)
