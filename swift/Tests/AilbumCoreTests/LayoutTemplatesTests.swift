import Foundation
import Testing

@testable import AilbumCore

private let orientations = ["vertical", "horizontal"]

private func byId(_ orientation: String, _ id: String) throws -> Template {
    try #require(try Templates.templatesFor(orientation).first { $0.id == id })
}

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@Suite struct LayoutTemplatesTests {
    @Test func formatValues() throws {
        let vertical = try Templates.formatFor("vertical")
        #expect(vertical.spreadWmm == 426.0)
        #expect(vertical.spreadHmm == 303.0)
        let horizontal = try Templates.formatFor("horizontal")
        #expect(horizontal.spreadWmm == 600.0)
        #expect(horizontal.spreadHmm == 216.0)
        #expect(vertical.bleedMm == 3.0 && vertical.safeMm == 3.0 && vertical.gapMm == 5.0)
        #expect(vertical.spineGuardMm == 8.0)
    }

    @Test func unknownOrientationRaises() {
        #expect(throws: AilbumError.invalid("Неизвестная ориентация: diagonal")) {
            try Templates.formatFor("diagonal")
        }
        #expect(throws: AilbumError.invalid("Неизвестная ориентация: diagonal")) {
            try Templates.templatesFor("diagonal")
        }
    }

    @Test(arguments: orientations) func cellsStayInsideSpread(orientation: String) throws {
        let fmt = try Templates.formatFor(orientation)
        let eps = 1e-9
        let templates = try Templates.templatesFor(orientation)
        #expect(!templates.isEmpty)
        for template in templates {
            #expect(template.cells.count == template.photoCount)
            for cell in template.cells {
                for rect in [cell.rect, cell.safe] {
                    #expect(rect.w > 0 && rect.h > 0, "\(template.id)")
                    #expect(rect.x >= -eps && rect.y >= -eps, "\(template.id)")
                    #expect(rect.x + rect.w <= fmt.spreadWmm + eps, "\(template.id)")
                    #expect(rect.y + rect.h <= fmt.spreadHmm + eps, "\(template.id)")
                }
                #expect(cell.safe.x >= cell.rect.x - eps)
                #expect(cell.safe.x + cell.safe.w <= cell.rect.x + cell.rect.w + eps)
                #expect(cell.safe.y >= cell.rect.y - eps)
                #expect(cell.safe.y + cell.safe.h <= cell.rect.y + cell.rect.h + eps)
            }
        }
    }

    @Test func safeStaysOffTrimEdge() throws {
        let fmt = try Templates.formatFor("vertical")
        let cell = try byId("vertical", "pages").cells[0]
        #expect(cell.rect.x == 0.0)
        #expect(cell.safe.x == fmt.bleedMm + fmt.safeMm)
    }

    @Test func spineBandOnlyWhenCrossing() throws {
        let fmt = try Templates.formatFor("vertical")
        let centre = fmt.spreadWmm / 2
        let wide = try byId("vertical", "wide_3").cells[0]
        let band = try #require(wide.spineBand)
        #expect(band.x == centre - fmt.spineGuardMm)
        #expect(band.w == 2 * fmt.spineGuardMm)
        #expect(band.y == wide.rect.y && band.h == wide.rect.h)
        #expect(try byId("vertical", "pages").cells.allSatisfy { $0.spineBand == nil })
        #expect(try byId("vertical", "full").cells[0].spineBand != nil)
        for orientation in orientations {
            let centre = try Templates.formatFor(orientation).spreadWmm / 2
            for template in try Templates.templatesFor(orientation) {
                for cell in template.cells {
                    let crosses = cell.rect.x < centre && centre < cell.rect.x + cell.rect.w
                    #expect((cell.spineBand != nil) == crosses, "\(template.id)")
                }
            }
        }
    }

    @Test func mirrorReflectsX() throws {
        let fmt = try Templates.formatFor("vertical")
        let base = try byId("vertical", "wide_3")
        let mirror = try byId("vertical", "wide_3_m")
        #expect(base.cells.count == mirror.cells.count)
        for (a, b) in zip(base.cells, mirror.cells) {
            #expect(near(b.rect.x, fmt.spreadWmm - a.rect.x - a.rect.w))
            #expect(b.rect.y == a.rect.y && b.rect.w == a.rect.w && b.rect.h == a.rect.h)
            #expect(near(b.safe.x, fmt.spreadWmm - a.safe.x - a.safe.w))
            #expect((b.spineBand == nil) == (a.spineBand == nil))
        }
    }

    @Test func mirrorVariantsExistOnlyForAsymmetric() throws {
        let ids = Set(try Templates.templatesFor("vertical").map(\.id))
        for name in ["page_2h", "page_2_2", "page_2_3", "wide_3", "inset_1_2"] {
            #expect(ids.contains(name) && ids.contains("\(name)_m"))
        }
        for name in ["full", "pages", "grid_2x2", "grid_65_35"] {
            #expect(ids.contains(name) && !ids.contains("\(name)_m"))
        }
    }

    @Test func page23Has6Cells() throws {
        #expect(try byId("vertical", "page_2_3").cells.count == 6)
    }

    @Test func templatesForPhotoCount() throws {
        #expect(try Templates.templatesFor("vertical", photoCount: 3).map(\.id) == [
            "page_2h", "page_2h_m", "row_3", "pano_2",
        ])
        #expect(try Templates.templatesFor("vertical", photoCount: 9).isEmpty)
        #expect(try Templates.templatesFor("horizontal", photoCount: 4).allSatisfy { $0.photoCount == 4 })
    }

    @Test func gapIs5mm() throws {
        let cells = try byId("vertical", "grid_2x2").cells
        #expect(near(cells[1].rect.x - (cells[0].rect.x + cells[0].rect.w), 5.0))
        #expect(near(cells[2].rect.y - (cells[0].rect.y + cells[0].rect.h), 5.0))
    }

    @Test func wide3Split() throws {
        let cell = try byId("vertical", "wide_3").cells[0]
        let right = cell.rect.x + cell.rect.w
        #expect(abs(right - 0.65 * 420.0) <= 2.0)
    }

    @Test func edgeCellsReachBleed() throws {
        let fmt = try Templates.formatFor("vertical")
        let cells = try byId("vertical", "pages").cells
        #expect(cells[0].rect.x == 0.0)
        #expect(cells[0].rect.y == 0.0)
        #expect(cells[1].rect.x + cells[1].rect.w == fmt.spreadWmm)
        #expect(cells[1].rect.y + cells[1].rect.h == fmt.spreadHmm)
    }

    @Test func insetKeepsMargin() throws {
        let cells = try byId("vertical", "inset_1_2").cells
        #expect(cells[0].rect.x == 9.0)
        #expect(cells[0].rect.y == 9.0)
        #expect(near(cells.map { $0.rect.x + $0.rect.w }.max()!, 426.0 - 9.0))
    }

    @Test func horizontalCatalogExcludesGrid2x2() throws {
        let ids = Set(try Templates.templatesFor("horizontal").map(\.id))
        #expect(!ids.contains("grid_2x2") && !ids.contains("grid_65_35"))
        #expect(ids.isSuperset(of: ["row_4", "page_3"]))
        #expect(try byId("horizontal", "row_4").cells.count == 4)
        #expect(try byId("horizontal", "page_3").cells.count == 4)
    }

    @Test func idsUniquePerOrientation() throws {
        for orientation in orientations {
            let ids = try Templates.templatesFor(orientation).map(\.id)
            #expect(ids.count == Set(ids).count)
        }
    }

    @Test func returnedListIsACopy() throws {
        var first = try Templates.templatesFor("vertical")
        first.removeAll()
        #expect(!(try Templates.templatesFor("vertical")).isEmpty)
    }

    @Test(arguments: orientations) func everyCountUpTo8HasChoice(orientation: String) throws {
        for count in 1...8 {
            #expect(try Templates.templatesFor(orientation, photoCount: count).count >= 2, "\(count)")
        }
    }

    @Test(arguments: [
        ("page_duo_wide", 4), ("page_stagger", 5), ("page_band", 5), ("page_hero_3", 5),
        ("page_cols_3_2", 6), ("page_brick", 7), ("page_grid_2x3", 7), ("page_corner", 7),
        ("page_pinwheel", 7), ("page_pinwheel_inset", 7), ("page_cols_3_4", 8),
    ]) func examplePagesPairWithFullPage(templateId: String, count: Int) throws {
        let fmt = try Templates.formatFor("vertical")
        for template in [try byId("vertical", templateId), try byId("vertical", "\(templateId)_m")] {
            #expect(template.photoCount == count)
            let full = template.cells.filter { $0.rect.w > fmt.pageWmm - 5 && $0.rect.h > 290 }
            #expect(full.count == 1)
            #expect(template.cells.allSatisfy { $0.spineBand == nil })
        }
    }

    @Test func pageInsetKeepsMarginOnItsPageOnly() throws {
        let fmt = try Templates.formatFor("vertical")
        let cells = try byId("vertical", "page_band").cells
        #expect(cells[0].rect.x == 0.0)
        let pageCells = cells.dropFirst()
        let centre = fmt.spreadWmm / 2
        #expect(near(pageCells.map(\.rect.x).min()!, centre + 12.0))
        #expect(near(pageCells.map(\.rect.y).min()!, fmt.bleedMm + 12.0))
    }

    @Test func horizontalPagesAreTransposed() throws {
        let cells = try byId("horizontal", "page_grid_2x3").cells.dropFirst()
        func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        #expect(Set(cells.map { r3($0.rect.x) }).count == 3)
        #expect(Set(cells.map { r3($0.rect.y) }).count == 2)
    }

    // Python golden (HF_HUB_OFFLINE=1 PYTHONPATH=src uv run python).
    @Test func templateIdsMatchPythonGolden() throws {
        let tail = [
            "full_inset", "pages_inset", "page_1_inset", "page_1_inset_m", "wide_1_1", "wide_1_1_m",
            "row_3", "pano_2", "page_duo_wide", "page_duo_wide_m", "page_stagger", "page_stagger_m",
            "page_band", "page_band_m", "page_hero_3", "page_hero_3_m", "page_cols_3_2",
            "page_cols_3_2_m", "page_brick", "page_brick_m", "page_grid_2x3", "page_grid_2x3_m",
            "page_corner", "page_corner_m", "page_pinwheel", "page_pinwheel_m", "page_cols_3_4",
            "page_cols_3_4_m", "page_pinwheel_inset", "page_pinwheel_inset_m",
        ]
        let vertical = [
            "full", "pages", "page_2h", "page_2h_m", "grid_2x2", "wide_3", "wide_3_m", "inset_1_2",
            "inset_1_2_m", "grid_65_35", "page_2_2", "page_2_2_m", "page_2_3", "page_2_3_m",
        ] + tail
        let horizontal = [
            "full", "pages", "page_2h", "page_2h_m", "row_4", "wide_3", "wide_3_m", "inset_1_2",
            "inset_1_2_m", "page_3", "page_3_m", "page_2_2", "page_2_2_m", "page_2_3", "page_2_3_m",
        ] + tail
        #expect(try Templates.templatesFor("vertical").map(\.id) == vertical)
        #expect(try Templates.templatesFor("horizontal").map(\.id) == horizontal)
        #expect(vertical.count == 44 && horizontal.count == 45)
    }

    @Test func cellRectsMatchPythonGolden() throws {
        func check(_ o: String, _ id: String, _ i: Int, _ rect: Rect, _ safe: Rect) throws {
            let cell = try byId(o, id).cells[i]
            for (got, want) in [(cell.rect, rect), (cell.safe, safe)] {
                #expect(near(got.x, want.x, 1e-9) && near(got.y, want.y, 1e-9), "\(id)")
                #expect(near(got.w, want.w, 1e-9) && near(got.h, want.h, 1e-9), "\(id)")
            }
        }
        let a = Rect(x: 9.0, y: 9.0, w: 201.5, h: 154.25)
        try check("vertical", "inset_1_2_m", 1, a, a)
        let b = Rect(x: 11.0, y: 83.75, w: 63.460000000000036, h: 65.25)
        try check("vertical", "page_pinwheel_inset_m", 3, b, b)
        try check(
            "vertical", "page_corner", 5, Rect(x: 215.5, y: 203.5, w: 65.0, h: 99.5),
            Rect(x: 215.5, y: 203.5, w: 65.0, h: 93.5))
        try check(
            "horizontal", "page_grid_2x3", 4, Rect(x: 401.5, y: 110.5, w: 94.0, h: 105.5),
            Rect(x: 401.5, y: 110.5, w: 94.0, h: 99.5))
        try check(
            "horizontal", "row_4", 2, Rect(x: 302.5, y: 0.0, w: 143.5, h: 216.0),
            Rect(x: 302.5, y: 6.0, w: 143.5, h: 204.0))
        try check(
            "horizontal", "page_3_m", 3, Rect(x: 0.0, y: 0.0, w: 99.5, h: 216.0),
            Rect(x: 6.0, y: 6.0, w: 93.5, h: 204.0))
    }
}
