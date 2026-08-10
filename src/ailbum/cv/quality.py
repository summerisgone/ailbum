from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np


@dataclass(slots=True)
class AnalysisImagePyramid:
    """Lazily build and reuse proportional downscales of one decoded image."""

    original: np.ndarray
    _images: dict[int, np.ndarray] = field(default_factory=dict, init=False, repr=False)

    def get(self, max_side: int) -> np.ndarray:
        if max_side < 1:
            raise ValueError("Analysis image size must be positive")
        if max_side in self._images:
            return self._images[max_side]
        candidates = [
            image
            for image in (self.original, *self._images.values())
            if max(image.shape[:2]) >= max_side
        ]
        source = (
            min(candidates, key=lambda image: max(image.shape[:2]))
            if candidates
            else self.original
        )
        resized, _ = resize_for_analysis(source, max_side)
        self._images[max_side] = resized
        return resized


def resize_for_analysis(image: np.ndarray, max_side: int) -> tuple[np.ndarray, float]:
    height, width = image.shape[:2]
    scale = min(1.0, max_side / max(height, width))
    if scale == 1.0:
        return image, scale
    resized = cv2.resize(image, (round(width * scale), round(height * scale)), interpolation=cv2.INTER_AREA)
    return resized, scale


def sharpness_score(image: np.ndarray, max_side: int = 1600) -> float:
    resized, _ = resize_for_analysis(image, max_side)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    # A mild denoise prevents JPEG blocks from masquerading as fine detail.
    gray = cv2.GaussianBlur(gray, (3, 3), 0)
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def exposure_score(image: np.ndarray, max_side: int = 800) -> float:
    resized, _ = resize_for_analysis(image, max_side)
    luminance = cv2.cvtColor(resized, cv2.COLOR_BGR2LAB)[:, :, 0].astype(np.float32) / 255.0
    clipped = float(np.mean((luminance < 0.03) | (luminance > 0.97)))
    mean_penalty = min(abs(float(luminance.mean()) - 0.5) / 0.5, 1.0)
    return max(0.0, 1.0 - 0.7 * clipped - 0.3 * mean_penalty)


def quality_score(sharpness: float, exposure: float) -> float:
    # Log compression keeps one extremely detailed photo from dominating a burst.
    sharp_component = min(np.log1p(max(sharpness, 0.0)) / np.log1p(1000.0), 1.0)
    return float(0.8 * sharp_component + 0.2 * exposure)
