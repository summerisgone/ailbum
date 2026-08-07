from __future__ import annotations

from pathlib import Path
from time import perf_counter

import numpy as np

from ailbum.cv.similarity import (
    GeometricFeatures,
    extract_geometric_features,
    extract_hash_color_features,
    geometric_scene_similarity,
    hamming_distance,
    histogram_similarity,
)
from ailbum.io import load_image


def compare_images(
    left_path: Path,
    right_path: Path,
    hash_distance: int = 12,
    histogram_threshold: float = 0.72,
    geometric_threshold: float = 0.55,
    geometric_max_features: int = 4000,
    max_image_side: int = 1600,
) -> dict[str, object]:
    started = perf_counter()
    left_image = load_image(left_path)
    right_image = load_image(right_path)
    loaded = perf_counter()

    left_hash, left_histogram = extract_hash_color_features(left_image)
    right_hash, right_histogram = extract_hash_color_features(right_image)
    hash_extracted = perf_counter()

    left_geometric = extract_geometric_features(
        left_image,
        max_features=geometric_max_features,
        max_image_side=max_image_side,
    )
    right_geometric = extract_geometric_features(
        right_image,
        max_features=geometric_max_features,
        max_image_side=max_image_side,
    )
    geometric_extracted = perf_counter()

    hash_value = hamming_distance(left_hash, right_hash)
    color_value = histogram_similarity(left_histogram, right_histogram)
    hash_compared = perf_counter()
    geometric = geometric_scene_similarity(left_geometric, right_geometric)
    geometric_compared = perf_counter()

    hash_color_match = hash_value <= hash_distance and color_value >= histogram_threshold
    geometric_match = geometric.score >= geometric_threshold
    return {
        "left": _image_description(left_path, left_image, left_geometric),
        "right": _image_description(right_path, right_image, right_geometric),
        "thresholds": {
            "hash_distance": hash_distance,
            "histogram_similarity": histogram_threshold,
            "geometric_scene_overlap": geometric_threshold,
        },
        "hash_color": {
            "hash_distance": hash_value,
            "color_similarity": round(color_value, 4),
            "similar": hash_color_match,
        },
        "geometric_scene_overlap": {
            **geometric.to_dict(),
            "similar": geometric_match,
        },
        "similar": hash_color_match or geometric_match,
        "matched_by": [
            name
            for name, matched in (
                ("hash_color", hash_color_match),
                ("geometric_scene_overlap", geometric_match),
            )
            if matched
        ],
        "timing_ms": {
            "load_images": _milliseconds(started, loaded),
            "extract_hash_color": _milliseconds(loaded, hash_extracted),
            "extract_geometric": _milliseconds(hash_extracted, geometric_extracted),
            "compare_hash_color": _milliseconds(geometric_extracted, hash_compared),
            "compare_geometric": _milliseconds(hash_compared, geometric_compared),
        },
    }


def _image_description(
    path: Path, image: np.ndarray, geometric: GeometricFeatures
) -> dict[str, object]:
    height, width = image.shape[:2]
    return {
        "path": str(path.resolve()),
        "width": width,
        "height": height,
        "orientation": "landscape" if width > height else "portrait" if height > width else "square",
        "geometric_features": len(geometric.keypoints),
    }


def _milliseconds(start: float, end: float) -> float:
    return round((end - start) * 1000.0, 3)
