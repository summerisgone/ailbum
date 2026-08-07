import cv2
import numpy as np

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

