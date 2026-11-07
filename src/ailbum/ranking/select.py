from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True, eq=False)
class Candidate:
    image_id: int
    score: float
    story_id: int | None
    similar_cluster: int | None
    embedding: np.ndarray | None


def _unit(vector: np.ndarray | None) -> np.ndarray | None:
    if vector is None:
        return None
    vector = np.asarray(vector, dtype=np.float64)
    norm = np.linalg.norm(vector)
    return vector / norm if norm > 0 else None


def select_for_target(candidates: list[Candidate], target: int, keep: list[int]) -> list[int]:
    """Keep first, then greedily fill to target: score minus 0.5 x max cosine to taken, stories first, no repeated similar cluster."""
    result = list(keep)
    by_id = {c.image_id: c for c in candidates}
    taken = [by_id[i] for i in keep if i in by_id]
    stories = {c.story_id for c in taken if c.story_id is not None}
    clusters = {c.similar_cluster for c in taken if c.similar_cluster is not None}
    units = [u for u in (_unit(c.embedding) for c in taken) if u is not None]
    remaining = sorted((c for c in candidates if c.image_id not in set(keep)), key=lambda c: c.image_id)

    def value(c: Candidate) -> float:
        unit = _unit(c.embedding)
        penalty = max((float(unit @ u) for u in units), default=0.0) if unit is not None else 0.0
        return c.score - 0.5 * penalty

    while len(result) < target and remaining:
        fresh = [c for c in remaining if c.similar_cluster is None or c.similar_cluster not in clusters]
        new_story = [c for c in fresh if c.story_id is None or c.story_id not in stories]
        pool = new_story or fresh or remaining
        best = max(pool, key=lambda c: (value(c), -c.image_id))
        remaining.remove(best)
        result.append(best.image_id)
        if best.story_id is not None:
            stories.add(best.story_id)
        if best.similar_cluster is not None:
            clusters.add(best.similar_cluster)
        unit = _unit(best.embedding)
        if unit is not None:
            units.append(unit)
    return result
