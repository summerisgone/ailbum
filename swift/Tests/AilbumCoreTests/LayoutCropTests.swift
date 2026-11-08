import Foundation
import Testing

@testable import AilbumCore

private func squareCell() -> Cell {
    Cell(
        index: 0, rect: Rect(x: 0, y: 0, w: 100, h: 100), safe: Rect(x: 0, y: 0, w: 100, h: 100),
        spineBand: nil)
}

private func hard(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Region {
    Region(bbox: Rect(x: x, y: y, w: w, h: h), weight: 1.0, hard: true, kind: "face")
}

private func near(_ a: Double, _ b: Double, abs tol: Double = 1e-6) -> Bool {
    Swift.abs(a - b) <= tol
}

@Suite struct LayoutCropTests {
    @Test func cropNoRegionsFullFrame() {
        let result = Crop.solve(photoAspect: 1.0, regions: [], cell: squareCell())
        #expect(result.rect == Rect(x: 0, y: 0, w: 1, h: 1))
        #expect(near(result.fit, 1.0))
        #expect(result.violations == [])
    }

    @Test func cropExtremeAspectPanorama() {
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 100, h: 143),
            safe: Rect(x: 3, y: 3, w: 94, h: 137), spineBand: nil)
        let result = Crop.solve(photoAspect: 8.0, regions: [], cell: cell)
        let r = result.rect
        #expect(r.x >= 0 && r.y >= 0)
        #expect(r.x + r.w <= 1 + 1e-9 && r.y + r.h <= 1 + 1e-9)
        #expect(0 < r.w && r.w < 1)
        #expect(0.0 <= result.fit && result.fit <= 1.0)
    }

    @Test func cropExtremeTallPhotoStaysInside() {
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 200, h: 100),
            safe: Rect(x: 0, y: 0, w: 200, h: 100), spineBand: nil)
        let r = Crop.solve(photoAspect: 0.05, regions: [], cell: cell).rect
        #expect(near(r.w, 1.0) || r.w <= 1)
        #expect(r.y >= 0 && r.y + r.h <= 1 + 1e-9)
    }

    @Test func cropFaceWiderThanWindow() {
        let result = Crop.solve(
            photoAspect: 2.0, regions: [hard(0.1, 0.1, 0.8, 0.6)], cell: squareCell())
        #expect(result.violations.contains("face_cut"))
        #expect(result.fit <= 0.5)
    }

    @Test func cropZeroAreaRegionIgnored() {
        let zero = Region(
            bbox: Rect(x: 0.5, y: 0.5, w: 0.0, h: 0.2), weight: 1.0, hard: true, kind: "face")
        #expect(
            Crop.solve(photoAspect: 1.5, regions: [zero], cell: squareCell())
                == Crop.solve(photoAspect: 1.5, regions: [], cell: squareCell()))
    }

    @Test func cropFaceAtLeftSlidesWindowLeft() {
        let result = Crop.solve(
            photoAspect: 1.5, regions: [hard(0.05, 0.3, 0.1, 0.2)], cell: squareCell())
        #expect(result.rect.x == 0)
        #expect(result.violations == [])
    }

    @Test func cropLandscapeInPortraitFitsLessThanPortrait() {
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 100, h: 140),
            safe: Rect(x: 0, y: 0, w: 100, h: 140), spineBand: nil)
        #expect(
            Crop.solve(photoAspect: 1.5, regions: [], cell: cell).fit
                < Crop.solve(photoAspect: 0.7, regions: [], cell: cell).fit)
    }

    @Test func cropFaceAvoidsSpine() {
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 400, h: 200),
            safe: Rect(x: 0, y: 0, w: 400, h: 200), spineBand: Rect(x: 192, y: 0, w: 16, h: 200))
        let result = Crop.solve(
            photoAspect: 2.0, regions: [hard(0.45, 0.3, 0.1, 0.2)], cell: cell)
        #expect(!result.violations.contains("face_on_spine"))
    }

    @Test func cropImpossibleFaceReportsViolation() {
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 100, h: 100),
            safe: Rect(x: 10, y: 10, w: 80, h: 80), spineBand: nil)
        let ok = Crop.solve(photoAspect: 1.0, regions: [], cell: cell)
        let bad = Crop.solve(photoAspect: 1.0, regions: [hard(0.0, 0.0, 1.0, 1.0)], cell: cell)
        #expect(bad.violations.contains("face_cut"))
        #expect(near(bad.fit, ok.fit - 0.5, abs: 0.05))
    }

    @Test func cropSoftRegionPreferred() {
        let soft = Region(
            bbox: Rect(x: 0.8, y: 0.2, w: 0.15, h: 0.4), weight: 0.6, hard: false, kind: "object")
        let r = Crop.solve(photoAspect: 1.5, regions: [soft], cell: squareCell()).rect
        #expect(r.x <= 0.8 && r.x + r.w >= 0.95 - 1e-9)
    }

    @Test func cropEvaluateMatchesSolve() {
        let regions = [
            hard(0.6, 0.2, 0.1, 0.2),
            Region(
                bbox: Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), weight: 0.5, hard: false,
                kind: "object"),
        ]
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 100, h: 140),
            safe: Rect(x: 3, y: 3, w: 94, h: 134), spineBand: nil)
        let solved = Crop.solve(photoAspect: 1.4, regions: regions, cell: cell)
        #expect(Crop.evaluate(rect: solved.rect, photoAspect: 1.4, regions: regions, cell: cell) == solved)
    }

    @Test func cropDeterministic() {
        let regions = [hard(0.3, 0.3, 0.1, 0.1)]
        #expect(
            Crop.solve(photoAspect: 1.3, regions: regions, cell: squareCell())
                == Crop.solve(photoAspect: 1.3, regions: regions, cell: squareCell()))
    }

    @Test func cropOffsetCellSpineMapping() {
        let cell = Cell(
            index: 0, rect: Rect(x: 100, y: 0, w: 226, h: 200),
            safe: Rect(x: 103, y: 3, w: 220, h: 194), spineBand: Rect(x: 205, y: 0, w: 16, h: 200))
        let face = Region(
            bbox: Rect(x: 0.49, y: 0.3, w: 0.02, h: 0.1), weight: 1.0, hard: true, kind: "face")
        let full = Crop.evaluate(
            rect: Rect(x: 0, y: 0, w: 1, h: 1), photoAspect: 1.13, regions: [face], cell: cell)
        #expect(full.violations.contains("face_on_spine"))
        let best = Crop.solve(photoAspect: 1.13, regions: [face], cell: cell)
        #expect(Crop.evaluate(rect: best.rect, photoAspect: 1.13, regions: [face], cell: cell) == best)
        #expect(best.fit >= full.fit)
    }

    @Test func cropMatchesPythonGolden() {
        let cell = Cell(
            index: 0, rect: Rect(x: 0, y: 0, w: 100, h: 140),
            safe: Rect(x: 3, y: 3, w: 94, h: 134), spineBand: Rect(x: 40, y: 0, w: 16, h: 140))
        let regions = [
            hard(0.6, 0.2, 0.1, 0.2),
            Region(bbox: Rect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), weight: 0.5, hard: false, kind: "object"),
            Region(bbox: Rect(x: 0.3, y: 0.5, w: 0.2, h: 0.2), weight: 0.3, hard: false, kind: "object"),
        ]
        let golden: [(Double, Double, Double, Double, Double)] = [
            (1.4, 0.24489795918367346, 0.5102040816326531, 1.0, 0.4454805054380562),
            (0.7, 0.0, 1.0, 0.9799999999999999, 0.9853156319536133),
            (2.2, 0.4051948051948052, 0.3246753246753247, 1.0, 0.24603881512529813),
        ]
        for (aspect, x, w, h, fit) in golden {
            let r = Crop.solve(photoAspect: aspect, regions: regions, cell: cell)
            #expect(near(r.rect.x, x, abs: 1e-12) && near(r.rect.y, 0, abs: 1e-12))
            #expect(near(r.rect.w, w, abs: 1e-12) && near(r.rect.h, h, abs: 1e-12))
            #expect(near(r.fit, fit, abs: 1e-12) && r.violations == [])
        }
    }
}
