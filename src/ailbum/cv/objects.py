from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

OBJECTS_FILENAME = "object_detection_yolox_2022nov.onnx"
DETECTOR_MODEL = "yolox_s_2022nov"

INPUT_SIZE = 640
PAD_VALUE = 114
STRIDES = (8, 16, 32)
SCORE_THRESHOLD = 0.35
NMS_THRESHOLD = 0.5

COCO_LABELS = (
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier",
    "toothbrush",
)  # fmt: skip


@dataclass(slots=True)
class DetectedObject:
    label: str
    score: float
    bbox: tuple[float, float, float, float]  # x, y, w, h as fractions of the input image


def _grid() -> tuple[np.ndarray, np.ndarray]:
    grids = []
    strides = []
    for stride in STRIDES:
        size = INPUT_SIZE // stride
        xv, yv = np.meshgrid(np.arange(size), np.arange(size))
        grids.append(np.stack((xv, yv), 2).reshape(-1, 2))
        strides.append(np.full((size * size, 1), stride))
    return np.concatenate(grids).astype(np.float32), np.concatenate(strides).astype(np.float32)


_GRIDS, _EXPANDED_STRIDES = _grid()


def letterbox(image: np.ndarray) -> tuple[np.ndarray, float]:
    """Resize into the top-left of a 640x640 canvas; returns the canvas and the scale."""
    height, width = image.shape[:2]
    scale = min(INPUT_SIZE / height, INPUT_SIZE / width)
    new_w = max(1, min(INPUT_SIZE, round(width * scale)))
    new_h = max(1, min(INPUT_SIZE, round(height * scale)))
    resized = cv2.resize(image, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((INPUT_SIZE, INPUT_SIZE, 3), PAD_VALUE, dtype=np.uint8)
    canvas[:new_h, :new_w] = resized
    return canvas, scale


def decode_detections(
    output: np.ndarray,
    scale: float,
    width: int,
    height: int,
    score_threshold: float = SCORE_THRESHOLD,
    nms_threshold: float = NMS_THRESHOLD,
) -> list[DetectedObject]:
    """Decode a YOLOX `(1, 8400, 85)` output into boxes normalized to the original image."""
    dets = np.array(output[0], dtype=np.float32)
    if dets.shape[0] != _GRIDS.shape[0]:
        raise ValueError(f"Unexpected detector output shape {output.shape}")
    scores = dets[:, 4:5] * dets[:, 5:]
    class_ids = np.argmax(scores, axis=1)
    best = scores[np.arange(scores.shape[0]), class_ids]
    keep = np.flatnonzero(best >= score_threshold)
    if keep.size == 0:
        return []

    centers = (dets[keep, :2] + _GRIDS[keep]) * _EXPANDED_STRIDES[keep]
    sizes = np.exp(np.clip(dets[keep, 2:4], -20.0, 10.0)) * _EXPANDED_STRIDES[keep]
    top_left = (centers - sizes / 2.0) / scale
    bottom_right = (centers + sizes / 2.0) / scale
    x0 = np.clip(top_left[:, 0], 0.0, width)
    y0 = np.clip(top_left[:, 1], 0.0, height)
    x1 = np.clip(bottom_right[:, 0], 0.0, width)
    y1 = np.clip(bottom_right[:, 1], 0.0, height)
    valid = (x1 - x0 > 0) & (y1 - y0 > 0)
    if not valid.any():
        return []
    x0, y0, x1, y1 = x0[valid], y0[valid], x1[valid], y1[valid]
    kept_scores = best[keep][valid]
    kept_classes = class_ids[keep][valid]

    boxes = np.stack([x0, y0, x1 - x0, y1 - y0], axis=1)
    indices = cv2.dnn.NMSBoxesBatched(
        boxes.tolist(),
        kept_scores.tolist(),
        kept_classes.tolist(),
        score_threshold,
        nms_threshold,
    )
    results = []
    for index in np.asarray(indices, dtype=int).reshape(-1):
        bx, by, bw, bh = boxes[index]
        results.append(
            DetectedObject(
                COCO_LABELS[int(kept_classes[index])],
                float(kept_scores[index]),
                (
                    float(bx / width),
                    float(by / height),
                    float(bw / width),
                    float(bh / height),
                ),
            )
        )
    results.sort(key=lambda item: (-item.score, item.bbox))
    return results


class ObjectDetector:
    def __init__(self, models_dir: Path) -> None:
        path = models_dir / OBJECTS_FILENAME
        if not path.exists():
            raise FileNotFoundError(f"Object detection model was not found: {path}")
        self._net = cv2.dnn.readNet(str(path))

    @staticmethod
    def available(models_dir: Path) -> bool:
        path = models_dir / OBJECTS_FILENAME
        return path.exists() and path.stat().st_size > 0

    def detect(self, image: np.ndarray) -> list[DetectedObject]:
        """Detect objects in an RGB uint8 image (height, width, 3)."""
        height, width = image.shape[:2]
        if height == 0 or width == 0:
            return []
        canvas, scale = letterbox(image)
        blob = np.transpose(canvas.astype(np.float32), (2, 0, 1))[np.newaxis]
        self._net.setInput(np.ascontiguousarray(blob))
        outputs = self._net.forward(self._net.getUnconnectedOutLayersNames())
        return decode_detections(outputs[0], scale, width, height)
