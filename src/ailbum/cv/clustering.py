from __future__ import annotations

from collections import defaultdict

import numpy as np


class UnionFind:
    def __init__(self, size: int) -> None:
        self.parent = list(range(size))
        self.rank = [0] * size

    def find(self, item: int) -> int:
        while self.parent[item] != item:
            self.parent[item] = self.parent[self.parent[item]]
            item = self.parent[item]
        return item

    def union(self, left: int, right: int) -> None:
        left_root, right_root = self.find(left), self.find(right)
        if left_root == right_root:
            return
        if self.rank[left_root] < self.rank[right_root]:
            left_root, right_root = right_root, left_root
        self.parent[right_root] = left_root
        if self.rank[left_root] == self.rank[right_root]:
            self.rank[left_root] += 1

    def components(self) -> list[list[int]]:
        groups: dict[int, list[int]] = defaultdict(list)
        for item in range(len(self.parent)):
            groups[self.find(item)].append(item)
        return sorted(groups.values(), key=lambda group: group[0])


def cluster_cosine(features: list[np.ndarray], threshold: float) -> list[list[int]]:
    """Complete-link cosine clustering.

    Every pair in a resulting cluster must meet the threshold. This intentionally
    avoids the common face-clustering failure where A~B and B~C merges dissimilar
    A and C through a long chain.
    """
    if not features:
        return []
    matrix = np.vstack(features).astype(np.float32)
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    matrix = matrix / np.maximum(norms, 1e-8)
    similarities = matrix @ matrix.T
    clusters = [[index] for index in range(len(features))]
    while True:
        best_pair: tuple[int, int] | None = None
        best_similarity = threshold
        for left in range(len(clusters)):
            for right in range(left + 1, len(clusters)):
                cross_similarity = min(
                    float(similarities[a, b]) for a in clusters[left] for b in clusters[right]
                )
                if cross_similarity >= best_similarity:
                    best_pair = (left, right)
                    best_similarity = cross_similarity
        if best_pair is None:
            break
        left, right = best_pair
        clusters[left].extend(clusters.pop(right))
        clusters[left].sort()
    return sorted(clusters, key=lambda group: group[0])
