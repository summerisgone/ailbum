from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

YUNET_FILENAME = "face_detection_yunet_2023mar.onnx"
SFACE_FILENAME = "face_recognition_sface_2021dec.onnx"
EYE_STATE_FILENAME = "open_closed_eye.onnx"
EXPRESSION_FILENAME = "facial_expression_recognition_mobilefacenet_2022july.onnx"

EXPRESSION_LABELS = ("angry", "disgust", "fearful", "happy", "neutral", "sad", "surprised")
_ALIGNED_EYES = {"right": (38, 52), "left": (74, 52)}


@dataclass(slots=True)
class FaceDetection:
    bbox: tuple[int, int, int, int]
    confidence: float
    raw: np.ndarray | None = None


@dataclass(slots=True)
class FaceAttributes:
    left_eye: str | None = None
    right_eye: str | None = None
    left_eye_open_probability: float | None = None
    right_eye_open_probability: float | None = None
    expression: str | None = None
    expression_confidence: float | None = None
    expression_scores: dict[str, float] | None = None

    @property
    def both_eyes_open(self) -> bool | None:
        if self.left_eye is None or self.right_eye is None:
            return None
        return self.left_eye == "open" and self.right_eye == "open"

    @property
    def smile_probability(self) -> float | None:
        if self.expression_scores is None:
            return None
        return self.expression_scores.get("happy")


@dataclass(slots=True)
class FaceAnalysis:
    detection: FaceDetection
    embedding: np.ndarray
    attributes: FaceAttributes


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
        min_attribute_face_size: int = 64,
    ) -> None:
        self.models_dir = models_dir
        self.min_face_size = min_face_size
        self.min_attribute_face_size = min_attribute_face_size
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

        eye_model = models_dir / EYE_STATE_FILENAME
        expression_model = models_dir / EXPRESSION_FILENAME
        self.eye_state_net = cv2.dnn.readNet(str(eye_model)) if eye_model.exists() else None
        self.expression_net = (
            cv2.dnn.readNet(str(expression_model)) if expression_model.exists() else None
        )
        eye_cascade_path = Path(cv2.data.haarcascades) / "haarcascade_eye_tree_eyeglasses.xml"
        self.eye_cascade = cv2.CascadeClassifier(str(eye_cascade_path))
        if self.eye_cascade.empty():
            self.eye_cascade = None

    @property
    def attribute_models(self) -> list[str]:
        models: list[str] = []
        if self.eye_state_net is not None:
            models.append("open-closed-eye-0001")
        if self.expression_net is not None:
            models.append("progressive-teacher-mobilefacenet-2022july")
        return models

    def analyze(self, image: np.ndarray) -> list[FaceAnalysis]:
        detections = self.detect(image)
        results: list[FaceAnalysis] = []
        for face in detections:
            aligned = self._align_face(image, face)
            attributes = (
                self.classify_attributes(aligned)
                if min(face.bbox[2:]) >= self.min_attribute_face_size
                else FaceAttributes()
            )
            results.append(
                FaceAnalysis(
                    detection=face,
                    embedding=self._embed_aligned(aligned),
                    attributes=attributes,
                )
            )
        return results

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
        return self._embed_aligned(self._align_face(image, face))

    def _align_face(self, image: np.ndarray, face: FaceDetection) -> np.ndarray:
        if self.backend == "dnn":
            assert self.recognizer is not None and face.raw is not None
            return self.recognizer.alignCrop(image, face.raw)
        crop = _crop_with_margin(image, face.bbox, margin=0.18)
        return cv2.resize(crop, (112, 112), interpolation=cv2.INTER_AREA)

    def _embed_aligned(self, aligned: np.ndarray) -> np.ndarray:
        if self.backend == "dnn":
            assert self.recognizer is not None
            feature = self.recognizer.feature(aligned).flatten().astype(np.float32)
            return _normalize(feature)
        return _classic_embedding(aligned)

    def classify_attributes(self, aligned_face: np.ndarray) -> FaceAttributes:
        attributes = FaceAttributes()
        if self.eye_state_net is not None:
            eye_centers = self._eye_centers(aligned_face)
            for side, center in eye_centers.items():
                patch = _square_crop(aligned_face, center, side=16)
                if patch is None:
                    continue
                probability = self._infer_eye_open_probability(patch)
                state = "open" if probability >= 0.5 else "closed"
                if side == "left":
                    attributes.left_eye = state
                    attributes.left_eye_open_probability = probability
                else:
                    attributes.right_eye = state
                    attributes.right_eye_open_probability = probability
        if self.expression_net is not None:
            scores = self._infer_expression(aligned_face)
            label = max(scores, key=scores.__getitem__)
            attributes.expression = label
            attributes.expression_confidence = scores[label]
            attributes.expression_scores = scores
        return attributes

    def _eye_centers(self, aligned_face: np.ndarray) -> dict[str, tuple[int, int]]:
        if self.backend == "dnn":
            return _ALIGNED_EYES.copy()
        if self.eye_cascade is None:
            return {}
        gray = cv2.cvtColor(aligned_face, cv2.COLOR_BGR2GRAY)
        upper = gray[: round(gray.shape[0] * 0.65)]
        boxes = self.eye_cascade.detectMultiScale(
            upper, scaleFactor=1.1, minNeighbors=4, minSize=(10, 10)
        )
        centers = sorted(
            ((int(x + width / 2), int(y + height / 2)) for x, y, width, height in boxes),
            key=lambda point: point[0],
        )
        if len(centers) < 2:
            return {}
        # Image-left is the subject's anatomical right eye.
        return {"right": centers[0], "left": centers[-1]}

    def _infer_eye_open_probability(self, eye: np.ndarray) -> float:
        assert self.eye_state_net is not None
        blob = cv2.dnn.blobFromImage(
            eye,
            scalefactor=1.0 / 255.0,
            size=(32, 32),
            mean=(127.0, 127.0, 127.0),
            swapRB=False,
        )
        self.eye_state_net.setInput(blob, "input.1")
        output = self.eye_state_net.forward("19").reshape(-1)
        probabilities = _as_probabilities(output)
        return round(float(probabilities[0]), 4)

    def _infer_expression(self, aligned_face: np.ndarray) -> dict[str, float]:
        assert self.expression_net is not None
        face = cv2.resize(aligned_face, (112, 112), interpolation=cv2.INTER_AREA)
        face = cv2.cvtColor(face, cv2.COLOR_BGR2RGB).astype(np.float32) / 127.5 - 1.0
        self.expression_net.setInput(cv2.dnn.blobFromImage(face), "data")
        output = self.expression_net.forward("label").reshape(-1)
        probabilities = _as_probabilities(output)
        return {
            label: round(float(probability), 4)
            for label, probability in zip(EXPRESSION_LABELS, probabilities)
        }


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


def _square_crop(
    image: np.ndarray, center: tuple[int, int], side: int
) -> np.ndarray | None:
    half = side // 2
    x, y = center
    left, top = max(0, x - half), max(0, y - half)
    right, bottom = min(image.shape[1], x + half), min(image.shape[0], y + half)
    crop = image[top:bottom, left:right]
    return crop if crop.size else None


def _as_probabilities(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=np.float32).reshape(-1)
    if values.size == 0:
        raise ValueError("Classifier returned an empty output")
    if np.all(values >= 0) and np.all(values <= 1) and np.isclose(values.sum(), 1.0, atol=1e-3):
        return values
    shifted = values - np.max(values)
    exponential = np.exp(shifted)
    return exponential / max(float(exponential.sum()), 1e-8)
