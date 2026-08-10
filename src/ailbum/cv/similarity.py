from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from math import exp, sqrt

import cv2
import numpy as np

from ailbum.cv.clustering import UnionFind

GEOMETRIC_PREFILTER_HASH_DISTANCE = 24
GEOMETRIC_PREFILTER_HISTOGRAM_SIMILARITY = 0.65


@dataclass(slots=True)
class GeometricFeatures:
    keypoints: np.ndarray
    descriptors: np.ndarray | None
    width: int
    height: int


@dataclass(slots=True)
class PhotoFeatures:
    phash: np.ndarray
    color_histogram: np.ndarray
    geometric: GeometricFeatures | None = None


@dataclass(frozen=True, slots=True)
class GeometricSimilarity:
    score: float
    mutual_matches: int
    inliers: int
    inlier_ratio: float
    coverage_left: float
    coverage_right: float

    def to_dict(self) -> dict[str, float | int]:
        return {
            "score": round(self.score, 4),
            "mutual_matches": self.mutual_matches,
            "inliers": self.inliers,
            "inlier_ratio": round(self.inlier_ratio, 4),
            "coverage_left": round(self.coverage_left, 4),
            "coverage_right": round(self.coverage_right, 4),
        }


@dataclass(frozen=True, slots=True)
class PhotoSimilarity:
    hash_distance: int
    color_similarity: float
    geometric: GeometricSimilarity
    hash_color_match: bool
    geometric_match: bool

    @property
    def similar(self) -> bool:
        return self.hash_color_match or self.geometric_match


def extract_hash_color_features(image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    gray = cv2.cvtColor(
        cv2.resize(image, (32, 32), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY
    )
    dct = cv2.dct(gray.astype(np.float32))[:8, :8]
    values = dct.flatten()
    phash = values > np.median(values[1:])

    hsv = cv2.cvtColor(
        cv2.resize(image, (256, 256), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2HSV
    )
    histogram = cv2.calcHist([hsv], [0, 1], None, [24, 16], [0, 180, 0, 256]).flatten()
    histogram = histogram.astype(np.float32)
    histogram /= max(float(np.linalg.norm(histogram)), 1e-8)
    return phash, histogram


def extract_geometric_features(
    image: np.ndarray,
    max_features: int = 4000,
    max_image_side: int = 1600,
) -> GeometricFeatures:
    height, width = image.shape[:2]
    scale = min(1.0, max_image_side / max(height, width))
    if scale < 1.0:
        image = cv2.resize(
            image,
            (max(1, round(width * scale)), max(1, round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    detector = cv2.SIFT_create(nfeatures=max_features, contrastThreshold=0.02)
    keypoints, descriptors = detector.detectAndCompute(gray, None)
    points = np.asarray([item.pt for item in keypoints], dtype=np.float32).reshape(-1, 2)
    return GeometricFeatures(
        keypoints=points,
        descriptors=descriptors,
        width=gray.shape[1],
        height=gray.shape[0],
    )


def extract_photo_features(
    image: np.ndarray,
    geometric_max_features: int = 4000,
    geometric_max_image_side: int = 1600,
    include_geometric: bool = True,
    hash_color_image: np.ndarray | None = None,
    geometric_image: np.ndarray | None = None,
) -> PhotoFeatures:
    phash, histogram = extract_hash_color_features(
        hash_color_image if hash_color_image is not None else image
    )
    geometric = None
    if include_geometric:
        geometric = extract_geometric_features(
            geometric_image if geometric_image is not None else image,
            max_features=geometric_max_features,
            max_image_side=geometric_max_image_side,
        )
    return PhotoFeatures(phash=phash, color_histogram=histogram, geometric=geometric)


def hamming_distance(left: np.ndarray, right: np.ndarray) -> int:
    return int(np.count_nonzero(left != right))


def histogram_similarity(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(left, right))


def geometric_scene_similarity(
    left: GeometricFeatures | None,
    right: GeometricFeatures | None,
    ratio_threshold: float = 0.75,
    ransac_reprojection_threshold: float = 4.0,
) -> GeometricSimilarity:
    empty = GeometricSimilarity(0.0, 0, 0, 0.0, 0.0, 0.0)
    if (
        left is None
        or right is None
        or left.descriptors is None
        or right.descriptors is None
        or len(left.descriptors) < 2
        or len(right.descriptors) < 2
    ):
        return empty

    matcher = cv2.BFMatcher(cv2.NORM_L2)
    forward = matcher.knnMatch(left.descriptors, right.descriptors, k=2)
    reverse = matcher.knnMatch(right.descriptors, left.descriptors, k=2)
    reverse_pairs = {
        (match.trainIdx, match.queryIdx)
        for match, neighbor in reverse
        if match.distance < ratio_threshold * neighbor.distance
    }
    mutual = [
        match
        for match, neighbor in forward
        if match.distance < ratio_threshold * neighbor.distance
        and (match.queryIdx, match.trainIdx) in reverse_pairs
    ]
    if len(mutual) < 4:
        return GeometricSimilarity(0.0, len(mutual), 0, 0.0, 0.0, 0.0)

    left_points = np.asarray(
        [left.keypoints[match.queryIdx] for match in mutual], dtype=np.float32
    )
    right_points = np.asarray(
        [right.keypoints[match.trainIdx] for match in mutual], dtype=np.float32
    )
    _, mask = cv2.findHomography(
        left_points,
        right_points,
        cv2.RANSAC,
        ransac_reprojection_threshold,
    )
    if mask is None:
        return GeometricSimilarity(0.0, len(mutual), 0, 0.0, 0.0, 0.0)

    inlier_mask = mask.reshape(-1).astype(bool)
    inliers = int(np.count_nonzero(inlier_mask))
    inlier_ratio = inliers / len(mutual)
    coverage_left = _keypoint_coverage(
        left_points[inlier_mask], left.width, left.height
    )
    coverage_right = _keypoint_coverage(
        right_points[inlier_mask], right.width, right.height
    )
    support = 1.0 - exp(-inliers / 80.0)
    coverage = sqrt(
        min(coverage_left / 0.25, 1.0) * min(coverage_right / 0.25, 1.0)
    )
    score = support * inlier_ratio * coverage
    return GeometricSimilarity(
        score=score,
        mutual_matches=len(mutual),
        inliers=inliers,
        inlier_ratio=inlier_ratio,
        coverage_left=coverage_left,
        coverage_right=coverage_right,
    )


def compare_photo_features(
    left: PhotoFeatures,
    right: PhotoFeatures,
    hash_distance: int,
    histogram_threshold: float,
    geometric_threshold: float | None = 0.55,
) -> PhotoSimilarity:
    hash_value = hamming_distance(left.phash, right.phash)
    color_value = histogram_similarity(left.color_histogram, right.color_histogram)
    geometric = geometric_scene_similarity(left.geometric, right.geometric)
    return PhotoSimilarity(
        hash_distance=hash_value,
        color_similarity=color_value,
        geometric=geometric,
        hash_color_match=hash_value <= hash_distance and color_value >= histogram_threshold,
        geometric_match=(
            geometric_threshold is not None and geometric.score >= geometric_threshold
        ),
    )


def is_geometric_candidate(
    hash_value: int,
    color_value: float,
    prefilter_hash_distance: int = GEOMETRIC_PREFILTER_HASH_DISTANCE,
    prefilter_histogram_similarity: float = GEOMETRIC_PREFILTER_HISTOGRAM_SIMILARITY,
) -> bool:
    """Use cheap global features to avoid quadratic SIFT matching for unlikely pairs."""
    return (
        hash_value <= prefilter_hash_distance
        or color_value >= prefilter_histogram_similarity
    )


def cluster_similar_photos(
    features: list[PhotoFeatures],
    hash_distance: int,
    histogram_threshold: float,
    geometric_threshold: float | None = 0.55,
    *,
    capture_times: list[str | None] | None = None,
    geometric_neighbor_window: int = 12,
    geometric_time_window_minutes: int = 15,
) -> list[list[int]]:
    if geometric_neighbor_window < 1:
        raise ValueError("Geometric neighbor window must be positive")
    if geometric_time_window_minutes < 1:
        raise ValueError("Geometric time window must be positive")
    if capture_times is not None and len(capture_times) != len(features):
        raise ValueError("Capture times must match the number of photo features")
    timestamps = [_timestamp(value) for value in capture_times] if capture_times else None
    groups = UnionFind(len(features))
    for left in range(len(features)):
        for right in range(left + 1, len(features)):
            left_feature = features[left]
            right_feature = features[right]
            hash_value = hamming_distance(left_feature.phash, right_feature.phash)
            color_value = histogram_similarity(
                left_feature.color_histogram, right_feature.color_histogram
            )
            hash_color_match = (
                hash_value <= hash_distance and color_value >= histogram_threshold
            )
            if hash_color_match:
                groups.union(left, right)
                continue
            if geometric_threshold is None or not is_geometric_candidate(
                hash_value, color_value
            ):
                continue
            if not _within_geometric_window(
                left,
                right,
                timestamps,
                geometric_neighbor_window,
                geometric_time_window_minutes,
            ):
                continue
            geometric = geometric_scene_similarity(
                left_feature.geometric, right_feature.geometric
            )
            if geometric.score >= geometric_threshold:
                groups.union(left, right)
    return groups.components()


def _within_geometric_window(
    left: int,
    right: int,
    timestamps: list[float | None] | None,
    neighbor_window: int,
    time_window_minutes: int,
) -> bool:
    if right - left <= neighbor_window:
        return True
    if timestamps is None or timestamps[left] is None or timestamps[right] is None:
        return False
    return abs(timestamps[right] - timestamps[left]) <= time_window_minutes * 60


def _timestamp(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        return datetime.fromisoformat(value).timestamp()
    except (ValueError, OSError, OverflowError):
        return None


def _keypoint_coverage(points: np.ndarray, width: int, height: int) -> float:
    if len(points) < 3 or width <= 0 or height <= 0:
        return 0.0
    hull = cv2.convexHull(points.reshape(-1, 1, 2))
    return float(cv2.contourArea(hull)) / (width * height)
