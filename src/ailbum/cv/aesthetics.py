from __future__ import annotations

import cv2
import numpy as np

from ailbum.cv.quality import resize_for_analysis
from ailbum.models import ColorRecord, CompositionRecord, SubjectRecord


def analyze_composition(
    image: np.ndarray,
    face_boxes: list[tuple[int, int, int, int]] | None = None,
    max_side: int = 800,
    analysis_image: np.ndarray | None = None,
) -> CompositionRecord:
    """Estimate subject placement and framing on a normalized 0..1 scale."""
    height, width = image.shape[:2]
    subject = _subject_from_faces(face_boxes or [], width, height)
    edge_energy = 0.0
    if subject is None:
        subject, edge_energy = _subject_from_saliency(
            analysis_image if analysis_image is not None else image, max_side
        )

    if subject is None:
        return CompositionRecord(
            rule_of_thirds=0.0,
            frame_occupancy=0.0,
            negative_space=1.0,
            crop_risk=round(edge_energy, 4),
            score=0.0,
        )

    x, y, box_width, box_height = subject.bbox
    occupancy = float(np.clip(box_width * box_height, 0.0, 1.0))
    thirds = _rule_of_thirds(subject.center)
    margin = min(x, y, 1.0 - x - box_width, 1.0 - y - box_height)
    boundary_risk = float(np.clip((0.04 - margin) / 0.04, 0.0, 1.0))
    crop_risk = max(boundary_risk, edge_energy)
    # A broad optimum avoids declaring either portraits or landscapes "wrong".
    occupancy_score = float(np.clip(1.0 - abs(occupancy - 0.35) / 0.55, 0.0, 1.0))
    score = 0.5 * thirds + 0.3 * (1.0 - crop_risk) + 0.2 * occupancy_score
    return CompositionRecord(
        rule_of_thirds=round(thirds, 4),
        frame_occupancy=round(occupancy, 4),
        negative_space=round(1.0 - occupancy, 4),
        crop_risk=round(crop_risk, 4),
        score=round(float(score), 4),
        main_subject=subject,
    )


def analyze_color(image: np.ndarray, max_side: int = 800) -> ColorRecord:
    """Estimate spatial color balance and simple hue-scheme harmony."""
    resized, _ = resize_for_analysis(image, max_side)
    hsv = cv2.cvtColor(resized, cv2.COLOR_BGR2HSV).astype(np.float32)
    saturation = hsv[:, :, 1] / 255.0
    value = hsv[:, :, 2] / 255.0
    weights = saturation * (0.25 + 0.75 * value)

    height, width = weights.shape
    total = float(weights.sum())
    if total <= 1e-6:
        balance = 1.0
    else:
        xs = (np.arange(width, dtype=np.float32) + 0.5) / width
        ys = (np.arange(height, dtype=np.float32) + 0.5) / height
        center_x = float((weights * xs[None, :]).sum() / total)
        center_y = float((weights * ys[:, None]).sum() / total)
        distance = np.hypot(center_x - 0.5, center_y - 0.5) / np.sqrt(0.5)
        balance = float(np.clip(1.0 - distance, 0.0, 1.0))

    harmony = _hue_harmony(hsv[:, :, 0], saturation)
    return ColorRecord(
        balance=round(balance, 4),
        harmony=round(harmony, 4),
        mean_saturation=round(float(saturation.mean()), 4),
    )


def _subject_from_faces(
    boxes: list[tuple[int, int, int, int]], width: int, height: int
) -> SubjectRecord | None:
    valid = [box for box in boxes if box[2] > 0 and box[3] > 0]
    if not valid or width <= 0 or height <= 0:
        return None
    x1 = min(box[0] for box in valid)
    y1 = min(box[1] for box in valid)
    x2 = max(box[0] + box[2] for box in valid)
    y2 = max(box[1] + box[3] for box in valid)
    return _normalized_subject(x1, y1, x2 - x1, y2 - y1, width, height, "faces")


def _subject_from_saliency(
    image: np.ndarray, max_side: int
) -> tuple[SubjectRecord | None, float]:
    resized, _ = resize_for_analysis(image, max_side)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    if float(gray.std()) < 1e-4:
        return None, 0.0

    spectrum = np.fft.fft2(gray)
    log_amplitude = np.log(np.abs(spectrum) + 1e-8)
    smooth = cv2.blur(log_amplitude.astype(np.float32), (3, 3))
    residual = log_amplitude - smooth
    saliency = np.abs(np.fft.ifft2(np.exp(residual + 1j * np.angle(spectrum)))) ** 2
    saliency = cv2.GaussianBlur(saliency.astype(np.float32), (9, 9), 2.5)
    saliency -= float(saliency.min())
    peak = float(saliency.max())
    if peak <= 1e-8:
        return None, 0.0
    saliency /= peak

    border = max(1, round(min(saliency.shape) * 0.04))
    edge_mask = np.zeros(saliency.shape, dtype=bool)
    edge_mask[:border, :] = True
    edge_mask[-border:, :] = True
    edge_mask[:, :border] = True
    edge_mask[:, -border:] = True
    edge_energy = float(saliency[edge_mask].sum() / max(float(saliency.sum()), 1e-8))
    edge_risk = float(np.clip(edge_energy / 0.22, 0.0, 1.0))

    cutoff = max(0.35, float(np.quantile(saliency, 0.82)))
    mask = np.uint8(saliency >= cutoff) * 255
    count, _, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if count <= 1:
        return None, edge_risk
    component = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    x, y, width, height, _ = stats[component]
    subject = _normalized_subject(
        int(x), int(y), int(width), int(height), resized.shape[1], resized.shape[0], "saliency"
    )
    return subject, edge_risk


def _normalized_subject(
    x: int, y: int, width: int, height: int, image_width: int, image_height: int, source: str
) -> SubjectRecord:
    bbox = (
        float(np.clip(x / image_width, 0.0, 1.0)),
        float(np.clip(y / image_height, 0.0, 1.0)),
        float(np.clip(width / image_width, 0.0, 1.0)),
        float(np.clip(height / image_height, 0.0, 1.0)),
    )
    center = (bbox[0] + bbox[2] / 2.0, bbox[1] + bbox[3] / 2.0)
    return SubjectRecord(
        bbox=tuple(round(value, 4) for value in bbox),  # type: ignore[arg-type]
        center=tuple(round(value, 4) for value in center),  # type: ignore[arg-type]
        source=source,
    )


def _rule_of_thirds(center: tuple[float, float]) -> float:
    intersections = ((1 / 3, 1 / 3), (2 / 3, 1 / 3), (1 / 3, 2 / 3), (2 / 3, 2 / 3))
    distance = min(np.hypot(center[0] - x, center[1] - y) for x, y in intersections)
    return float(np.exp(-0.5 * (distance / 0.22) ** 2))


def _hue_harmony(hue: np.ndarray, saturation: np.ndarray) -> float:
    colorful = saturation >= 0.12
    if not np.any(colorful):
        return 1.0
    histogram, _ = np.histogram(hue[colorful], bins=36, range=(0, 180), weights=saturation[colorful])
    dominant = (int(np.argmax(histogram)) + 0.5) * 5.0
    angles = hue[colorful] * 2.0
    dominant_angle = dominant * 2.0

    def circular_distance(target: float) -> np.ndarray:
        difference = np.abs(angles - target) % 360.0
        return np.minimum(difference, 360.0 - difference)

    schemes = (
        (dominant_angle,),
        (dominant_angle, (dominant_angle + 180.0) % 360.0),
        (
            dominant_angle,
            (dominant_angle + 120.0) % 360.0,
            (dominant_angle + 240.0) % 360.0,
        ),
    )
    weights = saturation[colorful]
    scores = []
    for scheme in schemes:
        distance = np.minimum.reduce([circular_distance(target) for target in scheme])
        membership = np.exp(-0.5 * (distance / 30.0) ** 2)
        scores.append(float(np.average(membership, weights=weights)))
    return float(np.clip(max(scores), 0.0, 1.0))
