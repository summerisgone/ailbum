from __future__ import annotations

from dataclasses import dataclass
from functools import cache

from ailbum.layout.types import Cell, Rect

_Node = str | tuple


@dataclass(frozen=True, slots=True)
class AlbumFormat:
    orientation: str
    page_w_mm: float
    page_h_mm: float
    bleed_mm: float = 3.0
    safe_mm: float = 3.0
    gap_mm: float = 5.0
    spine_guard_mm: float = 8.0

    @property
    def spread_w_mm(self) -> float:
        return 2 * self.page_w_mm + 2 * self.bleed_mm

    @property
    def spread_h_mm(self) -> float:
        return self.page_h_mm + 2 * self.bleed_mm


@dataclass(frozen=True, slots=True)
class Template:
    id: str
    photo_count: int
    orientation: str
    cells: tuple[Cell, ...]


_FORMATS = {
    "vertical": AlbumFormat("vertical", 210.0, 297.0),
    "horizontal": AlbumFormat("horizontal", 297.0, 210.0),
}

# Cut trees: ("V" | "H", cut positions, children); "C" is a cell.
_C = "C"
_THIRDS = (1 / 3, 2 / 3)
_PAGE_2_3 = ("V", (0.5,), (_C, ("V", (0.5,), (
    ("H", (0.5,), (_C, _C)), ("H", _THIRDS, (_C, _C, _C))))))

# (id, tree, inset mm, mirrored variant)
_VERTICAL: tuple[tuple[str, _Node, float, bool], ...] = (
    ("full", _C, 0.0, False),
    ("pages", ("V", (0.5,), (_C, _C)), 0.0, False),
    ("page_2h", ("V", (0.5,), (_C, ("H", (0.5,), (_C, _C)))), 0.0, True),
    ("grid_2x2", ("H", (0.5,), (("V", (0.5,), (_C, _C)), ("V", (0.5,), (_C, _C)))), 0.0, False),
    ("wide_3", ("V", (0.65,), (_C, ("H", _THIRDS, (_C, _C, _C)))), 0.0, True),
    ("inset_1_2",
     ("V", (0.5,), (_C, ("H", (0.55,), (_C, ("V", (0.5,), (_C, _C)))))), 6.0, True),
    ("grid_65_35",
     ("H", (0.5,), (("V", (0.65,), (_C, _C)), ("V", (0.65,), (_C, _C)))), 0.0, False),
    ("page_2_2",
     ("V", (0.5,), (_C, ("V", (0.5,), (("H", (0.5,), (_C, _C)), ("H", (0.5,), (_C, _C)))))),
     0.0, True),
    ("page_2_3", _PAGE_2_3, 0.0, True),
)

_ROW_4: tuple[str, _Node, float, bool] = (
    "row_4", ("V", (0.25, 0.5, 0.75), (_C, _C, _C, _C)), 0.0, False)
_PAGE_3: tuple[str, _Node, float, bool] = (
    "page_3", ("V", (0.5,), (_C, ("V", _THIRDS, (_C, _C, _C)))), 0.0, True)

_HORIZONTAL_REPLACED = {"grid_2x2": _ROW_4, "grid_65_35": _PAGE_3}


def format_for(orientation: str) -> AlbumFormat:
    try:
        return _FORMATS[orientation]
    except KeyError:
        raise ValueError(f"Неизвестная ориентация: {orientation}") from None


def templates_for(orientation: str, photo_count: int | None = None) -> list[Template]:
    templates = _catalog(orientation)
    if photo_count is None:
        return list(templates)
    return [t for t in templates if t.photo_count == photo_count]


@cache
def _catalog(orientation: str) -> tuple[Template, ...]:
    fmt = format_for(orientation)
    entries = _VERTICAL
    if orientation == "horizontal":
        entries = tuple(_HORIZONTAL_REPLACED.get(e[0], e) for e in _VERTICAL)
    result: list[Template] = []
    for template_id, tree, inset, mirrored in entries:
        base = _build(template_id, tree, inset, fmt)
        result.append(base)
        if mirrored:
            result.append(_mirror(base, fmt))
    return tuple(result)


def _build(template_id: str, tree: _Node, inset: float, fmt: AlbumFormat) -> Template:
    bleed = fmt.bleed_mm
    box = (bleed + inset, bleed + inset,
           fmt.spread_w_mm - bleed - inset, fmt.spread_h_mm - bleed - inset)
    # Side kinds: "edge" touches the trim, "cut" borders another cell.
    leaves: list[tuple[tuple[float, float, float, float], tuple[str, str, str, str]]] = []
    outer = "inset" if inset else "edge"
    _split(tree, box, (outer,) * 4, leaves)
    cells = tuple(_cell(i, b, s, fmt) for i, (b, s) in enumerate(leaves))
    return Template(template_id, len(cells), fmt.orientation, cells)


def _split(node: _Node, box, sides, leaves) -> None:
    if node == _C:
        leaves.append((box, sides))
        return
    axis, cuts, children = node
    x0, y0, x1, y1 = box
    start, end = (x0, x1) if axis == "V" else (y0, y1)
    bounds = [start] + [start + c * (end - start) for c in cuts] + [end]
    last = len(children) - 1
    for i, child in enumerate(children):
        a, b = bounds[i], bounds[i + 1]
        left, top, right, bottom = sides
        if axis == "V":
            child_box = (a, y0, b, y1)
            child_sides = (left if i == 0 else "cut", top, right if i == last else "cut", bottom)
        else:
            child_box = (x0, a, x1, b)
            child_sides = (left, top if i == 0 else "cut", right, bottom if i == last else "cut")
        _split(child, child_box, child_sides, leaves)


def _cell(index: int, box, sides, fmt: AlbumFormat) -> Cell:
    half_gap = fmt.gap_mm / 2
    # Moves each side outward (+) or inward (-) in the order left, top, right, bottom.
    x0, y0, x1, y1 = box
    shifts = []
    for side in sides:
        shifts.append(fmt.bleed_mm if side == "edge" else -half_gap if side == "cut" else 0.0)
    x0, y0 = x0 - shifts[0], y0 - shifts[1]
    x1, y1 = x1 + shifts[2], y1 + shifts[3]
    rect = Rect(x0, y0, x1 - x0, y1 - y0)
    return Cell(index, rect, _safe(rect, fmt), _spine_band(rect, fmt))


def _safe(rect: Rect, fmt: AlbumFormat) -> Rect:
    margin = fmt.bleed_mm + fmt.safe_mm
    x0 = max(rect.x, margin)
    y0 = max(rect.y, margin)
    x1 = min(rect.x + rect.w, fmt.spread_w_mm - margin)
    y1 = min(rect.y + rect.h, fmt.spread_h_mm - margin)
    return Rect(x0, y0, x1 - x0, y1 - y0)


def _spine_band(rect: Rect, fmt: AlbumFormat) -> Rect | None:
    centre = fmt.spread_w_mm / 2
    if not rect.x < centre < rect.x + rect.w:
        return None
    return Rect(centre - fmt.spine_guard_mm, rect.y, 2 * fmt.spine_guard_mm, rect.h)


def _mirror(template: Template, fmt: AlbumFormat) -> Template:
    def flip(rect: Rect) -> Rect:
        return Rect(fmt.spread_w_mm - rect.x - rect.w, rect.y, rect.w, rect.h)

    cells = tuple(
        Cell(c.index, flip(c.rect), flip(c.safe),
             flip(c.spine_band) if c.spine_band else None)
        for c in template.cells
    )
    return Template(f"{template.id}_m", template.photo_count, template.orientation, cells)
