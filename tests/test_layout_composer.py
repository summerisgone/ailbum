from __future__ import annotations

import time
from itertools import pairwise

from ailbum.layout.allocation import Allocation
from ailbum.layout.composer import best_variants, compose_group
from ailbum.layout.facts import PhotoFacts
from ailbum.layout.types import LayoutParams, Rect, Region


def photo(
    image_id: int,
    *,
    unit: str | None = None,
    aspect: float = 1.5,
    rank: float = 0.5,
    selected: bool = True,
    taken_at: str | None = None,
    regions: tuple[Region, ...] = (),
) -> PhotoFacts:
    return PhotoFacts(
        image_id,
        aspect,
        unit or f"image:{image_id}",
        1,
        taken_at if taken_at is not None else f"2026-01-01T10:{image_id % 60:02d}:00",
        rank,
        selected,
        regions,
    )


def alloc(units: int, spreads: int, merged: bool = False) -> Allocation:
    return Allocation((1,), units, spreads, merged)


def params(spreads: int = 2, low: int = 3, high: int = 3) -> LayoutParams:
    return LayoutParams("vertical", spreads, low, high)


def test_six_units_two_spreads():
    group = compose_group([photo(i) for i in range(1, 7)], alloc(6, 2), params())
    assert len(group.spreads) == 2
    assert all(len(s.placements) == 3 for s in group.spreads)
    assert group.unplaced == []


def test_each_unit_used_once():
    photos = [photo(i) for i in range(1, 10)]
    group = compose_group(photos, alloc(9, 3), params(3))
    ids = [p.image_id for s in group.spreads for p in s.placements]
    assert sorted(ids) == list(range(1, 10))


def test_time_order_between_spreads():
    photos = [photo(i, taken_at=f"2026-01-01T10:{60 - i:02d}:00") for i in range(1, 7)]
    group = compose_group(photos, alloc(6, 2), params())
    first = {p.image_id for p in group.spreads[0].placements}
    assert first == {4, 5, 6}


def test_no_adjacent_repeat_when_alternative_exists():
    photos = [photo(i) for i in range(1, 13)]
    group = compose_group(photos, alloc(12, 4), params(4))
    ids = [s.template_id for s in group.spreads]
    assert all(a != b for a, b in pairwise(ids))


def test_similar_picks_format_match():
    photos = []
    for unit, base in ((1, 1), (2, 3)):
        photos.append(photo(base, unit=f"cluster:{unit}", aspect=1.6, selected=True))
        photos.append(photo(base + 1, unit=f"cluster:{unit}", aspect=0.7, selected=False))
    group = compose_group(photos, alloc(2, 1), LayoutParams("vertical", 1, 2, 2))
    spread = group.spreads[0]
    assert spread.template_id.startswith("pages")
    assert {p.image_id for p in spread.placements} == {2, 4}
    assert {p.replaced_image_id for p in spread.placements} == {1, 3}


def test_selected_beats_equal_sibling():
    a = photo(1, unit="cluster:1", selected=False)
    b = photo(2, unit="cluster:1", selected=True)
    group = compose_group([a, b], alloc(1, 1), LayoutParams("vertical", 1, 1, 1))
    placement = group.spreads[0].placements[0]
    assert placement.image_id == 2
    assert placement.replaced_image_id is None


def test_hero_gets_largest_cell():
    photos = [photo(1, rank=0.1), photo(2, rank=0.2), photo(3, rank=1.0)]
    group = compose_group(photos, alloc(3, 1), LayoutParams("vertical", 1, 3, 3))
    spread = group.spreads[0]
    from ailbum.layout.templates import templates_for

    template = next(t for t in templates_for("vertical", 3) if t.id == spread.template_id)
    areas = {c.index: c.rect.w * c.rect.h for c in template.cells}
    hero = next(p for p in spread.placements if p.image_id == 3)
    assert areas[hero.cell_index] == max(areas.values())


def test_capacity_overflow_goes_unplaced():
    photos = [photo(i, rank=i / 100) for i in range(1, 21)]
    group = compose_group(photos, alloc(20, 2), LayoutParams("vertical", 2, 3, 6))
    assert len(group.unplaced) == 8
    assert {u["reason"] for u in group.unplaced} == {"capacity"}
    assert {u["image_id"] for u in group.unplaced} == set(range(1, 9))
    assert sum(len(s.placements) for s in group.spreads) == 12


def test_underfilled_marked():
    group = compose_group(
        [photo(1), photo(2)], alloc(2, 1), LayoutParams("vertical", 1, 3, 6)
    )
    assert "underfilled" in group.spreads[0].warnings


def test_merged_stories_warning():
    group = compose_group([photo(i) for i in range(1, 4)], alloc(3, 1, True), params(1))
    assert "merged_stories" in group.spreads[0].warnings


def test_deterministic():
    photos = [photo(i, aspect=0.7 + i / 10) for i in range(1, 10)]
    first = compose_group(photos, alloc(9, 3), params(3))
    second = compose_group(list(reversed(photos)), alloc(9, 3), params(3))
    assert first == second


def test_alternatives_same_photos():
    photos = [photo(i) for i in range(1, 4)]
    spread = compose_group(photos, alloc(3, 1), params(1)).spreads[0]
    assert 1 <= len(spread.alternatives) <= 2
    ids = sorted(p.image_id for p in spread.placements)
    for alt in spread.alternatives:
        assert alt.template_id != spread.template_id
        assert sorted(p.image_id for p in alt.placements) == ids


def test_best_variants_limit_and_order():
    variants = best_variants([photo(i) for i in range(1, 5)], params(1), limit=3)
    assert len(variants) == 3
    assert variants[0].score >= variants[1].score >= variants[2].score
    assert best_variants([photo(1)], params(1), limit=1)[0].template_id == "full"


def test_face_not_cut_in_placements():
    face = Region(Rect(0.05, 0.3, 0.1, 0.2), 1.0, True, "face")
    group = compose_group(
        [photo(1, regions=(face,)), photo(2), photo(3)], alloc(3, 1), params(1)
    )
    assert all(p.warnings == () for p in group.spreads[0].placements)


def test_100_units_under_5s():
    photos = [photo(i, aspect=0.6 + (i % 7) * 0.2) for i in range(1, 101)]
    start = time.perf_counter()
    group = compose_group(photos, alloc(100, 20), LayoutParams("vertical", 20, 3, 6))
    assert time.perf_counter() - start < 5
    assert sum(len(s.placements) for s in group.spreads) == 100


def test_selected_members_split_when_units_short():
    photos = [
        photo(1, unit="cluster:1"),
        photo(2, unit="cluster:1"),
        photo(3, unit="cluster:1", selected=False),
    ]
    group = compose_group(photos, alloc(1, 1), LayoutParams("vertical", 1, 2, 3))
    spread = group.spreads[0]
    assert "underfilled" not in spread.warnings
    assert sorted(p.image_id for p in spread.placements if p.image_id in (1, 2)) == [1, 2]


def test_no_split_when_units_enough():
    photos = [photo(1, unit="cluster:1"), photo(2, unit="cluster:1"), photo(3)]
    group = compose_group(photos, alloc(2, 1), LayoutParams("vertical", 1, 2, 3))
    assert len(group.spreads[0].placements) == 2


def test_no_story_ids_group():
    photos = [photo(i) for i in range(1, 4)]
    group = compose_group(photos, Allocation((), 3, 1, False), params(1, 3, 3))
    assert group.spreads[0].story_ids == ()
