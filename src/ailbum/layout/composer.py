from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, replace
from functools import lru_cache

from ailbum.layout.allocation import Allocation
from ailbum.layout.crop import solve_crop
from ailbum.layout.facts import PhotoFacts
from ailbum.layout.templates import Template, templates_for
from ailbum.layout.types import Cell, CropResult, LayoutParams, Rect, Region

SELECTED_BONUS = 0.15
RANK_WEIGHT = 0.25
REPEAT_COST = 0.15
UNDERFILL_COST = 1000.0
MAX_CELLS = 8


@dataclass(frozen=True, slots=True)
class PlacementDraft:
    cell_index: int
    image_id: int
    crop: Rect
    fit: float
    warnings: tuple[str, ...]
    replaced_image_id: int | None


@dataclass(frozen=True, slots=True)
class SpreadDraft:
    template_id: str
    story_ids: tuple[int, ...]
    placements: tuple[PlacementDraft, ...]
    score: float
    warnings: tuple[str, ...] = ()
    alternatives: tuple[SpreadDraft, ...] = ()
    assistant_reason: str | None = None


@dataclass(frozen=True, slots=True)
class ComposedGroup:
    spreads: list[SpreadDraft]
    unplaced: list[dict]


@lru_cache(maxsize=65536)
def _crop(aspect: float, regions: tuple[Region, ...], cell: Cell) -> CropResult:
    return solve_crop(aspect, regions, cell)


def _time_key(photo: PhotoFacts) -> tuple[bool, str, int]:
    return (photo.taken_at is None, photo.taken_at or "", photo.image_id)


class _Unit:
    __slots__ = ("members", "rank", "time_key")

    def __init__(self, members: Sequence[PhotoFacts]) -> None:
        self.members = sorted(members, key=lambda p: p.image_id)
        self.rank = max(p.rank for p in self.members)
        self.time_key = min(_time_key(p) for p in self.members)

    def replaced_for(self, placed: PhotoFacts) -> int | None:
        if placed.selected:
            return None
        selected = [p.image_id for p in self.members if p.selected]
        return selected[0] if selected else None


def _make_units(
    photos: Sequence[PhotoFacts], per_photo: bool, split_selected: bool = False
) -> list[_Unit]:
    """Units by similar group; with `split_selected` each selected member of a group stands alone.

    Unselected neighbours stay with the group's first selected member.
    """
    groups: dict[str, list[PhotoFacts]] = {}
    lead: dict[str, int] = {}
    if split_selected:
        for photo in photos:
            if photo.selected:
                lead[photo.unit_key] = min(lead.get(photo.unit_key, photo.image_id), photo.image_id)
    for photo in photos:
        if per_photo:
            key = f"photo:{photo.image_id}"
        elif split_selected and photo.selected:
            key = f"{photo.unit_key}#{photo.image_id}"
        elif split_selected and photo.unit_key in lead:
            key = f"{photo.unit_key}#{lead[photo.unit_key]}"
        else:
            key = photo.unit_key
        groups.setdefault(key, []).append(photo)
    return sorted((_Unit(m) for m in groups.values()), key=lambda u: u.time_key)


class _Filler:
    """Best unit-to-cell assignment for a template, with per-cell member choice."""

    def __init__(self, units: Sequence[_Unit]) -> None:
        self.units = units
        self._cells: dict[tuple[int, Cell], tuple[float, PhotoFacts, CropResult]] = {}

    def _best(self, unit_index: int, cell: Cell) -> tuple[float, PhotoFacts, CropResult]:
        key = (unit_index, cell)
        found = self._cells.get(key)
        if found is not None:
            return found
        best: tuple[float, PhotoFacts, CropResult] | None = None
        for photo in self.units[unit_index].members:
            result = _crop(photo.aspect, photo.regions, cell)
            fit = result.fit + (SELECTED_BONUS if photo.selected else 0.0)
            score = fit + RANK_WEIGHT * photo.rank
            if best is None or score > best[0]:
                best = (score, photo, result)
        assert best is not None
        self._cells[key] = best
        return best

    def fill(self, indexes: Sequence[int], template: Template):
        """Return (value, [(cell, unit_index)]) maximising the area-weighted score."""
        cells = template.cells
        total = sum(c.rect.w * c.rect.h for c in cells)
        n = len(cells)
        values = [
            [self._best(u, c)[0] * c.rect.w * c.rect.h / total for c in cells] for u in indexes
        ]
        size = 1 << n
        best = [float("-inf")] * size
        pick = [0] * size
        best[0] = 0.0
        for mask in range(1, size):
            column = mask.bit_count() - 1
            for u in range(n):
                if mask >> u & 1:
                    value = best[mask ^ (1 << u)] + values[u][column]
                    if value > best[mask]:
                        best[mask] = value
                        pick[mask] = u
        mask = size - 1
        assignment: list[tuple[Cell, int]] = []
        for column in range(n - 1, -1, -1):
            u = pick[mask]
            assignment.append((cells[column], indexes[u]))
            mask ^= 1 << u
        assignment.reverse()
        return best[size - 1], assignment

    def draft(
        self,
        template: Template,
        value: float,
        assignment,
        story_ids: tuple[int, ...],
        warnings: tuple[str, ...],
    ) -> SpreadDraft:
        placements = []
        for cell, unit_index in assignment:
            _, photo, result = self._best(unit_index, cell)
            placements.append(
                PlacementDraft(
                    cell.index,
                    photo.image_id,
                    result.rect,
                    result.fit,
                    result.violations,
                    self.units[unit_index].replaced_for(photo),
                )
            )
        return SpreadDraft(template.id, story_ids, tuple(placements), value, warnings)


def best_variants(
    photos: Sequence[PhotoFacts],
    params: LayoutParams,
    limit: int = 3,
) -> list[SpreadDraft]:
    """Best draft per template for exactly these photos, one cell each."""
    units = _make_units(photos, per_photo=True)
    if not 1 <= len(units) <= MAX_CELLS or limit < 1:
        return []
    filler = _Filler(units)
    indexes = list(range(len(units)))
    drafts = []
    for template in templates_for(params.orientation, len(units)):
        value, assignment = filler.fill(indexes, template)
        drafts.append(filler.draft(template, value, assignment, (), ()))
    drafts.sort(key=lambda d: (-d.score, d.template_id))
    return drafts[:limit]


def compose_group(
    photos: Sequence[PhotoFacts],
    allocation: Allocation,
    params: LayoutParams,
) -> ComposedGroup:
    units = _make_units(photos, per_photo=False)
    if not units:
        return ComposedGroup([], [])
    min_p = max(1, min(MAX_CELLS, params.min_photos))
    max_p = max(1, min(MAX_CELLS, params.max_photos))
    spreads_wanted = max(1, allocation.spreads)
    if len(units) < spreads_wanted * min_p:
        units = _make_units(photos, per_photo=False, split_selected=True)

    unplaced: list[dict] = []
    overflow = len(units) - spreads_wanted * max_p
    if overflow > 0:
        order = sorted(units, key=lambda u: (u.rank, -u.members[0].image_id))
        dropped = {id(u) for u in order[:overflow]}
        for unit in order[:overflow]:
            keeper = max(unit.members, key=lambda p: (p.selected, p.rank, -p.image_id))
            unplaced.append({"image_id": keeper.image_id, "reason": "capacity"})
        unplaced.sort(key=lambda item: item["image_id"])
        units = [u for u in units if id(u) not in dropped]

    chunks = _partition(units, min(spreads_wanted, len(units)), min_p, max_p, params.orientation)
    drafts = []
    for filler, template, value, assignment, size in chunks:
        warnings = []
        if size < min_p:
            warnings.append("underfilled")
        if allocation.merged:
            warnings.append("merged_stories")
        drafts.append(
            filler.draft(template, value, assignment, tuple(allocation.story_ids), tuple(warnings))
        )
    by_id = {p.image_id: p for p in photos}
    return ComposedGroup([_with_alternatives(d, by_id, params) for d in drafts], unplaced)


def _with_alternatives(
    draft: SpreadDraft, by_id: dict[int, PhotoFacts], params: LayoutParams
) -> SpreadDraft:
    photos = [by_id[p.image_id] for p in draft.placements]
    replaced = {p.image_id: p.replaced_image_id for p in draft.placements}
    others = [v for v in best_variants(photos, params, MAX_CELLS * 4)
              if v.template_id != draft.template_id][:2]
    alternatives = tuple(
        replace(
            v,
            story_ids=draft.story_ids,
            warnings=draft.warnings,
            placements=tuple(
                replace(p, replaced_image_id=replaced.get(p.image_id)) for p in v.placements
            ),
        )
        for v in others
    )
    return replace(draft, alternatives=alternatives)


def _partition(
    units: Sequence[_Unit], count: int, min_p: int, max_p: int, orientation: str
) -> list[tuple[_Filler, Template, float, list, int]]:
    """Split time-ordered units into `count` consecutive chunks, choosing templates by DP."""
    n = len(units)
    filler = _Filler(units)
    options: dict[tuple[int, int], list[tuple[Template, float, list]]] = {}

    def chunk_options(start: int, size: int):
        key = (start, size)
        if key not in options:
            indexes = list(range(start, start + size))
            options[key] = [
                (t, *filler.fill(indexes, t)) for t in templates_for(orientation, size)
            ]
        return options[key]

    # layers[i]: (chunks_done, last_template_id) -> (value, previous key, chunk)
    layers: list[dict] = [{} for _ in range(n + 1)]
    layers[0][(0, None)] = (0.0, None, None)
    for i in range(n):
        for state, (base, _, _) in list(layers[i].items()):
            done, last = state
            if done >= count:
                continue
            left = count - done - 1
            for size in range(1, min(max_p, n - i) + 1):
                rest = n - i - size
                if rest < left or rest > left * max_p:
                    continue
                penalty = UNDERFILL_COST * max(0, min_p - size)
                for template, value, assignment in chunk_options(i, size):
                    # A mirrored variant still repeats its base template.
                    shape = template.id.removesuffix("_m")
                    total = base + value - penalty - (REPEAT_COST if shape == last else 0.0)
                    key = (done + 1, shape)
                    current = layers[i + size].get(key)
                    if current is None or total > current[0]:
                        layers[i + size][key] = (
                            total, (i, state), (template, value, assignment, size))

    final = layers[n]
    key = max(
        (k for k in final if k[0] == count), key=lambda k: final[k][0], default=None
    )
    chunks = []
    position: tuple | None = (n, key)
    while position is not None and position[1] is not None and position[0] > 0:
        _, previous, chunk = layers[position[0]][position[1]]
        template, value, assignment, size = chunk
        chunks.append((filler, template, value, assignment, size))
        position = previous
    chunks.reverse()
    return chunks
