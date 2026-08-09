import cv2
import numpy as np

from ailbum.cv.aesthetics import analyze_color, analyze_composition
from ailbum.cv.quality import exposure_score, sharpness_score


def test_sharpness_separates_detailed_and_blurred_images() -> None:
    detailed = np.zeros((512, 512, 3), dtype=np.uint8)
    for y in range(0, 512, 32):
        for x in range(0, 512, 32):
            detailed[y : y + 32, x : x + 32] = 255 if (x + y) // 32 % 2 else 0
    blurred = cv2.GaussianBlur(detailed, (31, 31), 9)

    assert sharpness_score(detailed) > sharpness_score(blurred) * 10


def test_exposure_penalizes_clipping() -> None:
    balanced = np.full((100, 100, 3), 128, dtype=np.uint8)
    clipped = np.zeros((100, 100, 3), dtype=np.uint8)

    assert exposure_score(balanced) > exposure_score(clipped)


def test_composition_uses_faces_and_rewards_rule_of_thirds() -> None:
    image = np.full((300, 300, 3), 128, dtype=np.uint8)

    on_thirds = analyze_composition(image, [(80, 80, 40, 40)])
    centered = analyze_composition(image, [(130, 130, 40, 40)])

    assert on_thirds.main_subject is not None
    assert on_thirds.main_subject.source == "faces"
    assert on_thirds.rule_of_thirds > centered.rule_of_thirds
    assert abs(
        on_thirds.frame_occupancy
        - on_thirds.main_subject.bbox[2] * on_thirds.main_subject.bbox[3]
    ) < 0.0001
    assert on_thirds.negative_space == 1.0 - on_thirds.frame_occupancy


def test_composition_reports_crop_risk_for_subject_touching_edge() -> None:
    image = np.full((200, 300, 3), 128, dtype=np.uint8)

    safe = analyze_composition(image, [(50, 50, 50, 50)])
    cropped = analyze_composition(image, [(0, 50, 50, 50)])

    assert cropped.crop_risk > safe.crop_risk


def test_color_metrics_are_normalized_and_gray_is_harmonious() -> None:
    gray = np.full((100, 100, 3), 128, dtype=np.uint8)
    result = analyze_color(gray)

    assert result.balance == 1.0
    assert result.harmony == 1.0
    assert result.mean_saturation == 0.0
