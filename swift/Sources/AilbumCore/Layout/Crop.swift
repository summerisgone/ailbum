import Foundation

public enum Crop {
    static let scales: [Double] = [1.0, 0.9, 0.8]
    static let steps = 11
    static let hardCover = 0.98
    static let eps = 1e-9

    private static func area(_ r: Rect) -> Double {
        max(r.w, 0.0) * max(r.h, 0.0)
    }

    private static func intersect(_ a: Rect, _ b: Rect) -> Rect {
        let x0 = max(a.x, b.x)
        let y0 = max(a.y, b.y)
        let x1 = min(a.x + a.w, b.x + b.w)
        let y1 = min(a.y + a.h, b.y + b.h)
        return Rect(x: x0, y: y0, w: max(x1 - x0, 0.0), h: max(y1 - y0, 0.0))
    }

    private static func cover(_ region: Rect, _ visible: Rect) -> Double {
        area(intersect(region, visible)) / area(region)
    }

    private static func fullWindow(_ photoAspect: Double, _ cellAspect: Double) -> (Double, Double) {
        if photoAspect > cellAspect { return (cellAspect / photoAspect, 1.0) }
        return (1.0, photoAspect / cellAspect)
    }

    private static func toPhoto(_ mm: Rect, _ cell: Cell, _ window: Rect) -> Rect {
        let rect = cell.rect
        let sx = window.w / rect.w
        let sy = window.h / rect.h
        return Rect(
            x: window.x + (mm.x - rect.x) * sx,
            y: window.y + (mm.y - rect.y) * sy,
            w: mm.w * sx,
            h: mm.h * sy)
    }

    private static func positions(_ free: Double) -> [Double] {
        if free <= eps { return [0.0] }
        return (0..<steps).map { free * Double($0) / Double(steps - 1) }
    }

    public static func evaluate(
        rect: Rect, photoAspect: Double, regions: [Region], cell: Cell
    ) -> CropResult {
        let photoAspect = max(photoAspect, eps)
        let cellAspect = cell.rect.w / cell.rect.h
        let (fullW, fullH) = fullWindow(photoAspect, cellAspect)
        let scale = min(1.0, (rect.w / fullW + rect.h / fullH) / 2)

        let visible = intersect(toPhoto(cell.safe, cell, rect), rect)
        let band = cell.spineBand.map { toPhoto($0, cell, rect) }
        let live = regions.filter { area($0.bbox) > eps * eps }

        var violations = Set<String>()
        var softTotal = 0.0
        var softLost = 0.0
        for region in live {
            let c = cover(region.bbox, visible)
            if region.hard {
                if c < hardCover { violations.insert("face_cut") }
                if let band, area(intersect(region.bbox, band)) > eps * eps {
                    violations.insert("face_on_spine")
                }
            } else {
                softTotal += region.weight
                softLost += region.weight * (1 - c)
            }
        }
        let softLoss = softTotal > 0 ? softLost / softTotal : 0.0

        var weight = 0.0
        for r in live { weight += r.weight }
        var cx = 0.5
        var cy = 0.5
        if weight > 0 {
            var sx = 0.0
            var sy = 0.0
            for r in live {
                sx += r.weight * (r.bbox.x + r.bbox.w / 2)
                sy += r.weight * (r.bbox.y + r.bbox.h / 2)
            }
            cx = sx / weight
            cy = sy / weight
        }
        let dx = rect.x + rect.w / 2 - cx
        let dy = rect.y + rect.h / 2 - cy
        let centerDist = pow(dx * dx + dy * dy, 0.5)

        let retained = min(photoAspect / cellAspect, cellAspect / photoAspect)
        var fit = 0.55 * (scale * scale) * retained + 0.45 * (1 - softLoss) - 0.02 * centerDist
        if !violations.isEmpty { fit -= 0.5 }
        return CropResult(rect: rect, fit: min(1.0, max(0.0, fit)), violations: violations.sorted())
    }

    public static func solve(photoAspect: Double, regions: [Region], cell: Cell) -> CropResult {
        let photoAspect = max(photoAspect, eps)
        let (fullW, fullH) = fullWindow(photoAspect, cell.rect.w / cell.rect.h)
        var best: CropResult?
        for scale in scales {
            let w = fullW * scale
            let h = fullH * scale
            for y in positions(1.0 - h) {
                for x in positions(1.0 - w) {
                    let result = evaluate(
                        rect: Rect(x: x, y: y, w: w, h: h), photoAspect: photoAspect,
                        regions: regions, cell: cell)
                    if best == nil || result.fit > best!.fit + eps { best = result }
                }
            }
        }
        return best!
    }
}
