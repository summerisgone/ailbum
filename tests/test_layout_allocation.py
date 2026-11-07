from __future__ import annotations

import itertools

import pytest

from ailbum.layout.allocation import Allocation, StoryGroup, allocate_spreads as real_allocate


@pytest.fixture
def allocate():
    return real_allocate


def G(ids, n, start=None, end=None):
    return StoryGroup(tuple(ids), n, start, end)


def test_examples_split(allocate):
    assert allocate([G((1,), 12), G((2,), 8)], 5, 3, 6) == [
        Allocation((1,), 12, 3, False),
        Allocation((2,), 8, 2, False),
    ]


def test_small_story_merges(allocate):
    assert allocate([G((1,), 2), G((2,), 10)], 3, 3, 6) == [Allocation((1, 2), 12, 3, True)]


def test_more_groups_than_spreads_merges_first_smallest_pair(allocate):
    assert allocate([G((1,), 5), G((2,), 5), G((3,), 5)], 2, 3, 6) == [
        Allocation((1, 2), 10, 1, True),
        Allocation((3,), 5, 1, False),
    ]


def test_untimed_story_merges_into_previous(allocate):
    groups = [
        G((1,), 6, "2024-01-01T10:00:00", "2024-01-01T11:00:00"),
        G((2,), 6, "2024-01-01T11:05:00", "2024-01-01T12:00:00"),
        G((3,), 1),
    ]
    result = allocate(groups, 3, 3, 6)
    assert [a.story_ids for a in result] == [(1,), (2, 3)]
    assert result[1].merged and result[1].unit_count == 7


def test_untimed_first_story_merges_into_next(allocate):
    result = allocate([G((1,), 1), G((2,), 6, "2024-01-01T10:00:00", None)], 2, 3, 6)
    assert [a.story_ids for a in result] == [(1, 2)]


def test_small_story_merges_with_nearest_in_time(allocate):
    groups = [
        G((1,), 6, "2024-01-01T08:00:00", "2024-01-01T09:00:00"),
        G((2,), 1, "2024-01-03T08:00:00", "2024-01-03T08:30:00"),
        G((3,), 6, "2024-01-03T09:00:00", "2024-01-03T10:00:00"),
    ]
    result = allocate(groups, 3, 3, 6)
    assert [a.story_ids for a in result] == [(1,), (2, 3)]


def test_single_group_gets_all_spreads(allocate):
    assert allocate([G((7,), 20)], 4, 3, 6) == [Allocation((7,), 20, 4, False)]


def test_empty_groups(allocate):
    assert allocate([], 3, 3, 6) == []


def test_invalid_spread_count_raises(allocate):
    with pytest.raises(ValueError):
        allocate([G((1,), 5)], 0, 3, 6)


def test_more_spreads_than_units_penalised_not_raised(allocate):
    result = allocate([G((1,), 3), G((2,), 3)], 4, 3, 6)
    assert sum(a.spreads for a in result) == 4
    assert [a.spreads for a in result] == [2, 2]


def test_sum_equals_spread_count_for_many_shapes(allocate):
    for sizes in itertools.product([1, 2, 5, 9], repeat=3):
        for spreads in (1, 2, 3, 5, 8):
            groups = [G((i,), n) for i, n in enumerate(sizes)]
            result = allocate(groups, spreads, 3, 6)
            assert sum(a.spreads for a in result) == spreads
            assert all(a.spreads >= 1 for a in result)
            assert sum(a.unit_count for a in result) == sum(sizes)
            ids = [i for a in result for i in a.story_ids]
            assert ids == list(range(3))
