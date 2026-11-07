from __future__ import annotations

from collections.abc import Sequence

from ailbum.layout.types import Cell, CropResult, Rect, Region

SCALES = (1.0, 0.9, 0.8)
STEPS = 11
HARD_COVER = 0.98
EPS = 1e-9


def _area(rect: Rect) -> float:
    return max(rect.w, 0.0) * max(rect.h, 0.0)


def _intersect(a: Rect, b: Rect) -> Rect:
    x0, y0 = max(a.x, b.x), max(a.y, b.y)
    x1, y1 = min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
    return Rect(x0, y0, max(x1 - x0, 0.0), max(y1 - y0, 0.0))


def _cover(region: Rect, visible: Rect) -> float:
    return _area(_intersect(region, visible)) / _area(region)


def _full_window(photo_aspect: float, cell_aspect: float) -> tuple[float, float]:
    """Largest window of the cell's aspect inside the photo, in photo fractions."""
    if photo_aspect > cell_aspect:
        return cell_aspect / photo_aspect, 1.0
    return 1.0, photo_aspect / cell_aspect


def _to_photo(mm: Rect, cell: Cell, window: Rect) -> Rect:
    rect = cell.rect
    sx, sy = window.w / rect.w, window.h / rect.h
    return Rect(
        window.x + (mm.x - rect.x) * sx,
        window.y + (mm.y - rect.y) * sy,
        mm.w * sx,
        mm.h * sy,
    )


def _positions(free: float) -> list[float]:
    if free <= EPS:
        return [0.0]
    return [free * i / (STEPS - 1) for i in range(STEPS)]


def evaluate_crop(
    rect: Rect, photo_aspect: float, regions: Sequence[Region], cell: Cell
) -> CropResult:
    photo_aspect = max(photo_aspect, EPS)
    cell_aspect = cell.rect.w / cell.rect.h
    full_w, full_h = _full_window(photo_aspect, cell_aspect)
    scale = min(1.0, (rect.w / full_w + rect.h / full_h) / 2)

    visible = _intersect(_to_photo(cell.safe, cell, rect), rect)
    band = _to_photo(cell.spine_band, cell, rect) if cell.spine_band else None
    live = [r for r in regions if _area(r.bbox) > EPS * EPS]

    violations: set[str] = set()
    soft_total = soft_lost = 0.0
    for region in live:
        cover = _cover(region.bbox, visible)
        if region.hard:
            if cover < HARD_COVER:
                violations.add("face_cut")
            if band is not None and _area(_intersect(region.bbox, band)) > EPS * EPS:
                violations.add("face_on_spine")
        else:
            soft_total += region.weight
            soft_lost += region.weight * (1 - cover)
    soft_loss = soft_lost / soft_total if soft_total > 0 else 0.0

    weight = sum(r.weight for r in live)
    if weight > 0:
        cx = sum(r.weight * (r.bbox.x + r.bbox.w / 2) for r in live) / weight
        cy = sum(r.weight * (r.bbox.y + r.bbox.h / 2) for r in live) / weight
    else:
        cx = cy = 0.5
    center_dist = ((rect.x + rect.w / 2 - cx) ** 2 + (rect.y + rect.h / 2 - cy) ** 2) ** 0.5

    retained = min(photo_aspect / cell_aspect, cell_aspect / photo_aspect)
    fit = 0.55 * scale**2 * retained + 0.45 * (1 - soft_loss) - 0.02 * center_dist
    if violations:
        fit -= 0.5
    return CropResult(rect, min(1.0, max(0.0, fit)), tuple(sorted(violations)))


def solve_crop(photo_aspect: float, regions: Sequence[Region], cell: Cell) -> CropResult:
    photo_aspect = max(photo_aspect, EPS)
    full_w, full_h = _full_window(photo_aspect, cell.rect.w / cell.rect.h)
    best: CropResult | None = None
    for scale in SCALES:
        w, h = full_w * scale, full_h * scale
        for y in _positions(1.0 - h):
            for x in _positions(1.0 - w):
                result = evaluate_crop(Rect(x, y, w, h), photo_aspect, regions, cell)
                if best is None or result.fit > best.fit + EPS:
                    best = result
    assert best is not None
    return best
