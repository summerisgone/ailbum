from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

from ailbum.cv.clustering import UnionFind


@dataclass(slots=True)
class PhotoFeatures:
    phash: np.ndarray
    color_histogram: np.ndarray


def extract_photo_features(image: np.ndarray) -> PhotoFeatures:
    gray = cv2.cvtColor(cv2.resize(image, (32, 32), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
    dct = cv2.dct(gray.astype(np.float32))[:8, :8]
    values = dct.flatten()
    phash = values > np.median(values[1:])

    hsv = cv2.cvtColor(cv2.resize(image, (256, 256), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2HSV)
    histogram = cv2.calcHist([hsv], [0, 1], None, [24, 16], [0, 180, 0, 256]).flatten()
    histogram = histogram.astype(np.float32)
    histogram /= max(float(np.linalg.norm(histogram)), 1e-8)
    return PhotoFeatures(phash=phash, color_histogram=histogram)


def hamming_distance(left: np.ndarray, right: np.ndarray) -> int:
    return int(np.count_nonzero(left != right))


def histogram_similarity(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(left, right))


def cluster_similar_photos(
    features: list[PhotoFeatures], hash_distance: int, histogram_threshold: float
) -> list[list[int]]:
    groups = UnionFind(len(features))
    for left in range(len(features)):
        for right in range(left + 1, len(features)):
            hash_close = hamming_distance(features[left].phash, features[right].phash) <= hash_distance
            color_close = (
                histogram_similarity(
                    features[left].color_histogram, features[right].color_histogram
                )
                >= histogram_threshold
            )
            if hash_close and color_close:
                groups.union(left, right)
    return groups.components()

