import numpy as np

from ailbum.cv.clustering import UnionFind, cluster_cosine
from ailbum.cv.similarity import cluster_similar_photos, extract_photo_features


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
