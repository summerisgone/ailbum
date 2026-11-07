from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime

MISSING_UNIT_PENALTY = 1000.0


@dataclass(slots=True)
class StoryGroup:
    story_ids: tuple[int, ...]
    unit_count: int
    started_at: str | None
    ended_at: str | None


@dataclass(slots=True)
class Allocation:
    story_ids: tuple[int, ...]
    unit_count: int
    spreads: int
    merged: bool


def _parse(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed.replace(tzinfo=None)


def _gap_seconds(left: StoryGroup, right: StoryGroup) -> float | None:
    end = _parse(left.ended_at) or _parse(left.started_at)
    start = _parse(right.started_at) or _parse(right.ended_at)
    if end is None or start is None:
        return None
    return abs((start - end).total_seconds())


def _merge(left: StoryGroup, right: StoryGroup) -> StoryGroup:
    starts = [v for v in (left.started_at, right.started_at) if _parse(v)]
    ends = [v for v in (left.ended_at, right.ended_at) if _parse(v)]
    return StoryGroup(
        left.story_ids + right.story_ids,
        left.unit_count + right.unit_count,
        min(starts, key=_parse) if starts else None,
        max(ends, key=_parse) if ends else None,
    )


def _small_neighbor(groups: list[StoryGroup], index: int) -> int:
    """Index of the neighbour a too-small group merges with."""
    candidates = [i for i in (index - 1, index + 1) if 0 <= i < len(groups)]
    if len(candidates) == 1:
        return candidates[0]
    previous, following = candidates
    group = groups[index]
    if _parse(group.started_at) is None and _parse(group.ended_at) is None:
        return previous
    gap_previous = _gap_seconds(groups[previous], group)
    gap_following = _gap_seconds(group, groups[following])
    if gap_following is None:
        return previous
    if gap_previous is None:
        return following
    return following if gap_following < gap_previous else previous


def _distribute(groups: Sequence[StoryGroup], spread_count: int, min_photos: int) -> list[int]:
    target = sum(g.unit_count for g in groups) / spread_count
    count = len(groups)
    max_each = spread_count - (count - 1)

    def cost(group: StoryGroup, spreads: int) -> float:
        value = spreads * (group.unit_count / spreads - target) ** 2
        missing = spreads * min_photos - group.unit_count
        return value + MISSING_UNIT_PENALTY * max(0, missing)

    inf = float("inf")
    # best[i][used]: minimal cost for the first i groups using `used` spreads
    best = [[inf] * (spread_count + 1) for _ in range(count + 1)]
    choice = [[0] * (spread_count + 1) for _ in range(count + 1)]
    best[0][0] = 0.0
    for i, group in enumerate(groups, start=1):
        for used in range(i, spread_count + 1):
            for spreads in range(1, min(max_each, used - (i - 1)) + 1):
                previous = best[i - 1][used - spreads]
                if previous == inf:
                    continue
                total = previous + cost(group, spreads)
                if total < best[i][used]:
                    best[i][used] = total
                    choice[i][used] = spreads
    result = [0] * count
    used = spread_count
    for i in range(count, 0, -1):
        result[i - 1] = choice[i][used]
        used -= result[i - 1]
    return result


def allocate_spreads(
    groups: Sequence[StoryGroup],
    spread_count: int,
    min_photos: int,
    max_photos: int,
) -> list[Allocation]:
    if spread_count < 1:
        raise ValueError("spread_count must be at least 1")
    merged_groups = list(groups)
    if not merged_groups:
        return []

    while len(merged_groups) > 1:
        small = [i for i, g in enumerate(merged_groups) if g.unit_count < min_photos]
        if not small:
            break
        index = min(small, key=lambda i: (merged_groups[i].unit_count, i))
        other = _small_neighbor(merged_groups, index)
        low, high = sorted((index, other))
        merged_groups[low : high + 1] = [_merge(merged_groups[low], merged_groups[high])]

    while len(merged_groups) > spread_count:
        sums = [
            merged_groups[i].unit_count + merged_groups[i + 1].unit_count
            for i in range(len(merged_groups) - 1)
        ]
        low = sums.index(min(sums))
        merged_groups[low : low + 2] = [_merge(merged_groups[low], merged_groups[low + 1])]

    spreads = _distribute(merged_groups, spread_count, min_photos)
    return [
        Allocation(g.story_ids, g.unit_count, s, len(g.story_ids) > 1)
        for g, s in zip(merged_groups, spreads)
    ]
