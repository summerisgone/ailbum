from __future__ import annotations

import pytest

from ailbum.layout import crop
from ailbum.layout.types import Cell, Rect, Region


@pytest.fixture
def solver():
    # SUPERLITE_REAL has no fake here: the producer is this module itself.
    return crop


def square_cell() -> Cell:
    return Cell(0, Rect(0, 0, 100, 100), Rect(0, 0, 100, 100), None)


def hard(x: float, y: float, w: float, h: float) -> Region:
    return Region(Rect(x, y, w, h), 1.0, True, "face")


def test_no_regions_full_frame(solver):
    result = solver.solve_crop(1.0, [], square_cell())
    assert result.rect == Rect(0, 0, 1, 1)
    assert result.fit == pytest.approx(1.0)
    assert result.violations == ()


def test_extreme_aspect_panorama(solver):
    cell = Cell(0, Rect(0, 0, 100, 143), Rect(3, 3, 94, 137), None)
    result = solver.solve_crop(8.0, [], cell)
    r = result.rect
    assert r.x >= 0 and r.y >= 0
    assert r.x + r.w <= 1 + 1e-9 and r.y + r.h <= 1 + 1e-9
    assert 0 < r.w < 1
    assert 0.0 <= result.fit <= 1.0


def test_extreme_tall_photo_stays_inside(solver):
    result = solver.solve_crop(0.05, [], Cell(0, Rect(0, 0, 200, 100), Rect(0, 0, 200, 100), None))
    r = result.rect
    assert r.w == pytest.approx(1.0) or r.w <= 1
    assert r.y >= 0 and r.y + r.h <= 1 + 1e-9


def test_face_wider_than_window(solver):
    result = solver.solve_crop(2.0, [hard(0.1, 0.1, 0.8, 0.6)], square_cell())
    assert "face_cut" in result.violations
    assert result.fit <= 0.5


def test_zero_area_region_ignored(solver):
    zero = Region(Rect(0.5, 0.5, 0.0, 0.2), 1.0, True, "face")
    assert solver.solve_crop(1.5, [zero], square_cell()) == solver.solve_crop(
        1.5, [], square_cell()
    )


def test_face_at_left_slides_window_left(solver):
    result = solver.solve_crop(1.5, [hard(0.05, 0.3, 0.1, 0.2)], square_cell())
    assert result.rect.x == 0
    assert result.violations == ()


def test_landscape_in_portrait_fits_less_than_portrait(solver):
    cell = Cell(0, Rect(0, 0, 100, 140), Rect(0, 0, 100, 140), None)
    assert solver.solve_crop(1.5, [], cell).fit < solver.solve_crop(0.7, [], cell).fit


def test_face_avoids_spine(solver):
    cell = Cell(
        0,
        Rect(0, 0, 400, 200),
        Rect(0, 0, 400, 200),
        Rect(192, 0, 16, 200),
    )
    result = solver.solve_crop(2.0, [hard(0.45, 0.3, 0.1, 0.2)], cell)
    assert "face_on_spine" not in result.violations


def test_impossible_face_reports_violation(solver):
    cell = Cell(0, Rect(0, 0, 100, 100), Rect(10, 10, 80, 80), None)
    ok = solver.solve_crop(1.0, [], cell)
    bad = solver.solve_crop(1.0, [hard(0.0, 0.0, 1.0, 1.0)], cell)
    assert "face_cut" in bad.violations
    assert bad.fit == pytest.approx(ok.fit - 0.5, abs=0.05)


def test_soft_region_preferred(solver):
    soft = Region(Rect(0.8, 0.2, 0.15, 0.4), 0.6, False, "object")
    result = solver.solve_crop(1.5, [soft], square_cell())
    r = result.rect
    assert r.x <= 0.8 and r.x + r.w >= 0.95 - 1e-9


def test_evaluate_matches_solve(solver):
    regions = [hard(0.6, 0.2, 0.1, 0.2), Region(Rect(0.1, 0.1, 0.1, 0.1), 0.5, False, "object")]
    cell = Cell(0, Rect(0, 0, 100, 140), Rect(3, 3, 94, 134), None)
    solved = solver.solve_crop(1.4, regions, cell)
    assert solver.evaluate_crop(solved.rect, 1.4, regions, cell) == solved


def test_deterministic(solver):
    regions = [hard(0.3, 0.3, 0.1, 0.1)]
    assert solver.solve_crop(1.3, regions, square_cell()) == solver.solve_crop(
        1.3, regions, square_cell()
    )
