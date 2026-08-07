import cv2
import numpy as np

from ailbum.cv.clustering import UnionFind, cluster_cosine
from ailbum.cv.similarity import (
    cluster_similar_photos,
    compare_photo_features,
    extract_photo_features,
)


def test_union_find_components() -> None:
    groups = UnionFind(4)
    groups.union(0, 2)
    groups.union(2, 3)

    assert groups.components() == [[0, 2, 3], [1]]


def test_cosine_clustering() -> None:
    features = [
        np.array([1.0, 0.0]),
        np.array([0.99, 0.05]),
        np.array([0.0, 1.0]),
    ]

    assert cluster_cosine(features, threshold=0.9) == [[0, 1], [2]]


def test_cosine_clustering_does_not_chain_dissimilar_ends() -> None:
    angles = np.deg2rad([0, 20, 40])
    features = [np.array([np.cos(angle), np.sin(angle)]) for angle in angles]

    groups = cluster_cosine(features, threshold=0.9)

    assert len(groups) == 2
    assert sorted(map(len, groups)) == [1, 2]


def test_photo_clustering_groups_near_duplicates() -> None:
    first = np.zeros((256, 256, 3), dtype=np.uint8)
    first[30:180, 60:210] = (30, 180, 220)
    duplicate = first.copy()
    different = np.zeros_like(first)
    different[:, ::16] = (255, 255, 255)
    features = [extract_photo_features(item) for item in (first, duplicate, different)]

    assert cluster_similar_photos(features, 8, 0.8) == [[0, 1], [2]]


def test_geometric_similarity_groups_rotated_scene_when_phash_does_not() -> None:
    scene = np.zeros((600, 800, 3), dtype=np.uint8)
    generator = np.random.default_rng(42)
    for index in range(160):
        x = int(generator.integers(20, 780))
        y = int(generator.integers(20, 580))
        radius = int(generator.integers(3, 14))
        color = tuple(int(value) for value in generator.integers(30, 255, size=3))
        cv2.circle(scene, (x, y), radius, color, -1)
        if index % 12 == 0:
            cv2.putText(
                scene,
                str(index),
                (x, y),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.7,
                (255, 255, 255),
                2,
            )
    rotated = cv2.rotate(scene, cv2.ROTATE_90_CLOCKWISE)
    features = [
        extract_photo_features(item, geometric_max_features=2000, geometric_max_image_side=800)
        for item in (scene, rotated)
    ]

    similarity = compare_photo_features(
        features[0],
        features[1],
        hash_distance=-1,
        histogram_threshold=2.0,
        geometric_threshold=0.55,
    )

    assert similarity.hash_color_match is False
    assert similarity.geometric_match is True
    assert similarity.geometric.score > 0.8
    assert similarity.geometric.inliers > 100
    assert cluster_similar_photos(features, -1, 2.0, 0.55) == [[0, 1]]
