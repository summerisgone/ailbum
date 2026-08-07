from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

YUNET_FILENAME = "face_detection_yunet_2023mar.onnx"
SFACE_FILENAME = "face_recognition_sface_2021dec.onnx"


@dataclass(slots=True)
class FaceDetection:
    bbox: tuple[int, int, int, int]
    confidence: float
    raw: np.ndarray | None = None


class FaceAnalyzer:
    """Detect faces and produce comparable, L2-normalized embeddings.

    YuNet + SFace is preferred when both ONNX files exist. The classical fallback
    deliberately has no external model download and is useful for bootstrapping,
    but its identity grouping is less robust to pose and lighting.
    """

    def __init__(
        self,
        models_dir: Path,
        backend: str = "auto",
        min_face_size: int = 40,
    ) -> None:
        self.models_dir = models_dir
        self.min_face_size = min_face_size
        yunet_path = models_dir / YUNET_FILENAME
        sface_path = models_dir / SFACE_FILENAME
        dnn_ready = yunet_path.exists() and sface_path.exists()

        if backend == "dnn" and not dnn_ready:
            raise FileNotFoundError(
                f"DNN face models were not found in {models_dir}. "
                "Run `ailbum download-models` first."
            )
        self.backend = "dnn" if backend == "dnn" or (backend == "auto" and dnn_ready) else "classic"

        if self.backend == "dnn":
            self.detector = cv2.FaceDetectorYN.create(
                str(yunet_path), "", (320, 320), 0.75, 0.3, 5000
            )
            self.recognizer = cv2.FaceRecognizerSF.create(str(sface_path), "")
            self.cascade = None
        else:
            cascade_path = Path(cv2.data.haarcascades) / "haarcascade_frontalface_default.xml"
            self.cascade = cv2.CascadeClassifier(str(cascade_path))
            if self.cascade.empty():
                raise RuntimeError(f"Unable to load OpenCV face cascade: {cascade_path}")
            self.detector = None
            self.recognizer = None

    def analyze(self, image: np.ndarray) -> list[tuple[FaceDetection, np.ndarray]]:
        detections = self.detect(image)
        return [(face, self.embed(image, face)) for face in detections]

    def detect(self, image: np.ndarray) -> list[FaceDetection]:
        if self.backend == "dnn":
            return self._detect_dnn(image)
        return self._detect_classic(image)

    def _detect_dnn(self, image: np.ndarray) -> list[FaceDetection]:
        height, width = image.shape[:2]
        assert self.detector is not None
        self.detector.setInputSize((width, height))
        _, rows = self.detector.detect(image)
        if rows is None:
            return []
        result: list[FaceDetection] = []
        for row in rows:
            x, y, w, h = (round(value) for value in row[:4])
            x, y = max(0, x), max(0, y)
            w, h = min(w, width - x), min(h, height - y)
            if min(w, h) >= self.min_face_size:
                result.append(FaceDetection((x, y, w, h), float(row[-1]), row.copy()))
        return result

    def _detect_classic(self, image: np.ndarray) -> list[FaceDetection]:
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        longest = max(gray.shape)
        scale = min(1.0, 1800 / longest)
        small = (
            cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            if scale < 1.0
            else gray
        )
        assert self.cascade is not None
        boxes, _, weights = self.cascade.detectMultiScale3(
            small,
            scaleFactor=1.1,
            minNeighbors=5,
            minSize=(max(20, round(self.min_face_size * scale)),) * 2,
            outputRejectLevels=True,
        )
        result: list[FaceDetection] = []
        for box, weight in zip(boxes, weights):
            x, y, w, h = (round(int(value) / scale) for value in box)
            confidence = float(1.0 / (1.0 + np.exp(-float(weight))))
            result.append(FaceDetection((x, y, w, h), confidence))
        return result

    def embed(self, image: np.ndarray, face: FaceDetection) -> np.ndarray:
        if self.backend == "dnn":
            assert self.recognizer is not None and face.raw is not None
            aligned = self.recognizer.alignCrop(image, face.raw)
            feature = self.recognizer.feature(aligned).flatten().astype(np.float32)
            return _normalize(feature)
        return _classic_embedding(_crop_with_margin(image, face.bbox, margin=0.18))


def _crop_with_margin(
    image: np.ndarray, bbox: tuple[int, int, int, int], margin: float
) -> np.ndarray:
    x, y, width, height = bbox
    dx, dy = round(width * margin), round(height * margin)
    left, top = max(0, x - dx), max(0, y - dy)
    right = min(image.shape[1], x + width + dx)
    bottom = min(image.shape[0], y + height + dy)
    return image[top:bottom, left:right]


def _classic_embedding(face: np.ndarray) -> np.ndarray:
    resized = cv2.resize(face, (96, 96), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    gray = cv2.equalizeHist(gray)

    hog = cv2.HOGDescriptor((96, 96), (16, 16), (8, 8), (8, 8), 9)
    hog_feature = hog.compute(gray).flatten().astype(np.float32)
    hog_feature = _normalize(hog_feature)

    hsv = cv2.cvtColor(resized, cv2.COLOR_BGR2HSV)
    histogram = cv2.calcHist([hsv], [0, 1], None, [12, 8], [0, 180, 0, 256]).flatten()
    histogram = _normalize(histogram.astype(np.float32))

    # Weighted concatenation keeps structure dominant while retaining skin/hair color.
    return _normalize(np.concatenate([hog_feature * 0.85, histogram * 0.15]))


def _normalize(feature: np.ndarray) -> np.ndarray:
    return feature / max(float(np.linalg.norm(feature)), 1e-8)
