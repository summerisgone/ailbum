from __future__ import annotations

import pytest

from ailbum.layout.templates import format_for, templates_for

ORIENTATIONS = ("vertical", "horizontal")


def by_id(orientation, template_id):
    return next(t for t in templates_for(orientation) if t.id == template_id)


def test_format_values():
    vertical = format_for("vertical")
    assert vertical.spread_w_mm == 426.0
    assert vertical.spread_h_mm == 303.0
    horizontal = format_for("horizontal")
    assert horizontal.spread_w_mm == 600.0
    assert horizontal.spread_h_mm == 216.0
    assert (vertical.bleed_mm, vertical.safe_mm, vertical.gap_mm) == (3.0, 3.0, 5.0)
    assert vertical.spine_guard_mm == 8.0


def test_unknown_orientation_raises():
    with pytest.raises(ValueError):
        format_for("diagonal")
    with pytest.raises(ValueError):
        templates_for("diagonal")


@pytest.mark.parametrize("orientation", ORIENTATIONS)
def test_cells_stay_inside_spread(orientation):
    fmt = format_for(orientation)
    eps = 1e-9
    templates = templates_for(orientation)
    assert templates
    for template in templates:
        assert len(template.cells) == template.photo_count
        for cell in template.cells:
            for rect in (cell.rect, cell.safe):
                assert rect.w > 0 and rect.h > 0, template.id
                assert rect.x >= -eps and rect.y >= -eps, template.id
                assert rect.x + rect.w <= fmt.spread_w_mm + eps, template.id
                assert rect.y + rect.h <= fmt.spread_h_mm + eps, template.id
            assert cell.safe.x >= cell.rect.x - eps
            assert cell.safe.x + cell.safe.w <= cell.rect.x + cell.rect.w + eps
            assert cell.safe.y >= cell.rect.y - eps
            assert cell.safe.y + cell.safe.h <= cell.rect.y + cell.rect.h + eps


def test_safe_stays_off_trim_edge():
    fmt = format_for("vertical")
    cell = by_id("vertical", "pages").cells[0]
    assert cell.rect.x == 0.0
    assert cell.safe.x == fmt.bleed_mm + fmt.safe_mm


def test_spine_band_only_when_crossing():
    fmt = format_for("vertical")
    centre = fmt.spread_w_mm / 2
    wide = by_id("vertical", "wide_3").cells[0]
    assert wide.spine_band is not None
    assert wide.spine_band.x == centre - fmt.spine_guard_mm
    assert wide.spine_band.w == 2 * fmt.spine_guard_mm
    assert (wide.spine_band.y, wide.spine_band.h) == (wide.rect.y, wide.rect.h)
    assert all(c.spine_band is None for c in by_id("vertical", "pages").cells)
    assert by_id("vertical", "full").cells[0].spine_band is not None
    for orientation in ORIENTATIONS:
        centre = format_for(orientation).spread_w_mm / 2
        for template in templates_for(orientation):
            for cell in template.cells:
                crosses = cell.rect.x < centre < cell.rect.x + cell.rect.w
                assert (cell.spine_band is not None) == crosses, template.id


def test_mirror_reflects_x():
    fmt = format_for("vertical")
    base = by_id("vertical", "wide_3")
    mirror = by_id("vertical", "wide_3_m")
    assert len(base.cells) == len(mirror.cells)
    for a, b in zip(base.cells, mirror.cells):
        assert b.rect.x == pytest.approx(fmt.spread_w_mm - a.rect.x - a.rect.w)
        assert (b.rect.y, b.rect.w, b.rect.h) == (a.rect.y, a.rect.w, a.rect.h)
        assert b.safe.x == pytest.approx(fmt.spread_w_mm - a.safe.x - a.safe.w)
        assert (b.spine_band is None) == (a.spine_band is None)


def test_mirror_variants_exist_only_for_asymmetric():
    ids = {t.id for t in templates_for("vertical")}
    for name in ("page_2h", "page_2_2", "page_2_3", "wide_3", "inset_1_2"):
        assert name in ids and f"{name}_m" in ids
    for name in ("full", "pages", "grid_2x2", "grid_65_35"):
        assert name in ids and f"{name}_m" not in ids


def test_page_2_3_has_6_cells():
    assert len(by_id("vertical", "page_2_3").cells) == 6


def test_templates_for_photo_count():
    assert [t.id for t in templates_for("vertical", 3)] == [
        "page_2h", "page_2h_m", "row_3", "pano_2"]
    assert templates_for("vertical", 9) == []
    assert all(t.photo_count == 4 for t in templates_for("horizontal", 4))


def test_gap_is_5mm():
    cells = by_id("vertical", "grid_2x2").cells
    assert cells[1].rect.x - (cells[0].rect.x + cells[0].rect.w) == pytest.approx(5.0)
    assert cells[2].rect.y - (cells[0].rect.y + cells[0].rect.h) == pytest.approx(5.0)


def test_wide_3_split():
    cell = by_id("vertical", "wide_3").cells[0]
    right = cell.rect.x + cell.rect.w
    assert abs(right - 0.65 * 420.0) <= 2.0


def test_edge_cells_reach_bleed():
    fmt = format_for("vertical")
    cells = by_id("vertical", "pages").cells
    assert cells[0].rect.x == 0.0
    assert cells[0].rect.y == 0.0
    assert cells[1].rect.x + cells[1].rect.w == fmt.spread_w_mm
    assert cells[1].rect.y + cells[1].rect.h == fmt.spread_h_mm


def test_inset_keeps_margin():
    cells = by_id("vertical", "inset_1_2").cells
    assert cells[0].rect.x == 9.0
    assert cells[0].rect.y == 9.0
    assert max(c.rect.x + c.rect.w for c in cells) == pytest.approx(426.0 - 9.0)


def test_horizontal_catalog_excludes_grid_2x2():
    ids = {t.id for t in templates_for("horizontal")}
    assert "grid_2x2" not in ids and "grid_65_35" not in ids
    assert {"row_4", "page_3"} <= ids
    assert len(by_id("horizontal", "row_4").cells) == 4
    assert len(by_id("horizontal", "page_3").cells) == 4


def test_ids_unique_per_orientation():
    for orientation in ORIENTATIONS:
        ids = [t.id for t in templates_for(orientation)]
        assert len(ids) == len(set(ids))


def test_returned_list_is_a_copy():
    templates_for("vertical").clear()
    assert templates_for("vertical")


@pytest.mark.parametrize("orientation", ORIENTATIONS)
def test_every_count_up_to_8_has_choice(orientation):
    for count in range(1, 9):
        assert len(templates_for(orientation, count)) >= 2, count


@pytest.mark.parametrize(
    ("template_id", "count"),
    [("page_duo_wide", 4), ("page_stagger", 5), ("page_band", 5), ("page_hero_3", 5),
     ("page_cols_3_2", 6), ("page_brick", 7), ("page_grid_2x3", 7), ("page_corner", 7),
     ("page_pinwheel", 7), ("page_pinwheel_inset", 7), ("page_cols_3_4", 8)],
)
def test_example_pages_pair_with_full_page(template_id, count):
    fmt = format_for("vertical")
    for template in (by_id("vertical", template_id), by_id("vertical", f"{template_id}_m")):
        assert template.photo_count == count
        full = [c for c in template.cells if c.rect.w > fmt.page_w_mm - 5 and c.rect.h > 290]
        assert len(full) == 1
        assert all(c.spine_band is None for c in template.cells)


def test_page_inset_keeps_margin_on_its_page_only():
    fmt = format_for("vertical")
    cells = by_id("vertical", "page_band").cells
    assert cells[0].rect.x == 0.0
    page_cells = cells[1:]
    centre = fmt.spread_w_mm / 2
    assert min(c.rect.x for c in page_cells) == pytest.approx(centre + 12.0)
    assert min(c.rect.y for c in page_cells) == pytest.approx(fmt.bleed_mm + 12.0)


def test_horizontal_pages_are_transposed():
    cells = by_id("horizontal", "page_grid_2x3").cells[1:]
    assert len({round(c.rect.x, 3) for c in cells}) == 3
    assert len({round(c.rect.y, 3) for c in cells}) == 2
