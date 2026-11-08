import Foundation

public struct AlbumFormat: Equatable, Sendable {
    public var orientation: String
    public var pageWmm: Double
    public var pageHmm: Double
    public var bleedMm: Double
    public var safeMm: Double
    public var gapMm: Double
    public var spineGuardMm: Double

    public init(
        orientation: String, pageWmm: Double, pageHmm: Double, bleedMm: Double = 3,
        safeMm: Double = 3, gapMm: Double = 5, spineGuardMm: Double = 8
    ) {
        self.orientation = orientation
        self.pageWmm = pageWmm
        self.pageHmm = pageHmm
        self.bleedMm = bleedMm
        self.safeMm = safeMm
        self.gapMm = gapMm
        self.spineGuardMm = spineGuardMm
    }

    public var spreadWmm: Double { 2 * pageWmm + 2 * bleedMm }
    public var spreadHmm: Double { pageHmm + 2 * bleedMm }
}

public struct Template: Equatable, Sendable {
    public var id: String
    public var photoCount: Int
    public var orientation: String
    public var cells: [Cell]

    public init(id: String, photoCount: Int, orientation: String, cells: [Cell]) {
        self.id = id
        self.photoCount = photoCount
        self.orientation = orientation
        self.cells = cells
    }
}

public enum Templates {
    // Cut trees: vertical/horizontal cuts at fractions; inset shrinks the box; cell is a leaf.
    private indirect enum Node {
        case cell
        case inset(Double, Node)
        case cut(vertical: Bool, [Double], [Node])
    }

    private struct Entry {
        let id: String
        let tree: Node
        let inset: Double
        let mirrored: Bool
    }

    private static let c = Node.cell
    private static let thirds = [1.0 / 3.0, 2.0 / 3.0]

    private static func v(_ cuts: [Double], _ kids: Node...) -> Node { .cut(vertical: true, cuts, kids) }
    private static func h(_ cuts: [Double], _ kids: Node...) -> Node { .cut(vertical: false, cuts, kids) }
    private static func pages(_ left: Node, _ right: Node) -> Node { v([0.5], left, right) }

    private static let formats: [String: AlbumFormat] = [
        "vertical": AlbumFormat(orientation: "vertical", pageWmm: 210, pageHmm: 297),
        "horizontal": AlbumFormat(orientation: "horizontal", pageWmm: 297, pageHmm: 210),
    ]

    private static let page23: Node = v([0.5], c, v([0.5], h([0.5], c, c), h(thirds, c, c, c)))

    private static let verticalEntries: [Entry] = [
        Entry(id: "full", tree: c, inset: 0, mirrored: false),
        Entry(id: "pages", tree: v([0.5], c, c), inset: 0, mirrored: false),
        Entry(id: "page_2h", tree: v([0.5], c, h([0.5], c, c)), inset: 0, mirrored: true),
        Entry(id: "grid_2x2", tree: h([0.5], v([0.5], c, c), v([0.5], c, c)), inset: 0, mirrored: false),
        Entry(id: "wide_3", tree: v([0.65], c, h(thirds, c, c, c)), inset: 0, mirrored: true),
        Entry(
            id: "inset_1_2", tree: v([0.5], c, h([0.55], c, v([0.5], c, c))), inset: 6, mirrored: true),
        Entry(
            id: "grid_65_35", tree: h([0.5], v([0.65], c, c), v([0.65], c, c)), inset: 0, mirrored: false),
        Entry(
            id: "page_2_2", tree: v([0.5], c, v([0.5], h([0.5], c, c), h([0.5], c, c))), inset: 0,
            mirrored: true),
        Entry(id: "page_2_3", tree: page23, inset: 0, mirrored: true),
    ]

    private static let pageLayouts: [(String, Node)] = [
        ("page_duo_wide", h([0.5], v([0.5], c, c), c)),
        ("page_stagger", v([0.5], h([0.6], c, c), h([0.4], c, c))),
        ("page_band", .inset(12, h([0.375, 0.625], c, v([0.5], c, c), c))),
        ("page_hero_3", .inset(8, h([0.64], c, v(thirds, c, c, c)))),
        ("page_cols_3_2", v([0.5], h(thirds, c, c, c), h([0.5], c, c))),
        ("page_brick", h(thirds, v([0.65], c, c), v([0.35], c, c), v([0.65], c, c))),
        ("page_grid_2x3", h(thirds, v([0.5], c, c), v([0.5], c, c), v([0.5], c, c))),
        ("page_corner", h([1.0 / 3.0], v(thirds, c, c, c), v([1.0 / 3.0], h([0.5], c, c), c))),
        ("page_pinwheel", pinwheel),
        ("page_cols_3_4", v([0.5], h([0.25, 0.75], c, c, c), h([0.25, 0.5, 0.75], c, c, c, c))),
    ]

    private static let pinwheel: Node = h(
        [0.5], v([0.66], c, h([0.5], c, c)), v([0.34], h([0.5], c, c), c))

    private static let pinwheelInset = ("page_pinwheel_inset", Node.inset(8, pinwheel))

    private static let fewEntries: [Entry] = [
        Entry(id: "full_inset", tree: c, inset: 15, mirrored: false),
        Entry(id: "pages_inset", tree: pages(.inset(12, c), .inset(12, c)), inset: 0, mirrored: false),
        Entry(id: "page_1_inset", tree: pages(c, .inset(20, c)), inset: 0, mirrored: true),
        Entry(id: "wide_1_1", tree: v([0.62], c, c), inset: 0, mirrored: true),
        Entry(id: "row_3", tree: v(thirds, c, c, c), inset: 0, mirrored: false),
        Entry(id: "pano_2", tree: h([0.6], c, v([0.5], c, c)), inset: 0, mirrored: false),
    ]

    private static let row4 = Entry(
        id: "row_4", tree: v([0.25, 0.5, 0.75], c, c, c, c), inset: 0, mirrored: false)
    private static let page3 = Entry(
        id: "page_3", tree: v([0.5], c, v(thirds, c, c, c)), inset: 0, mirrored: true)

    nonisolated(unsafe) private static var cache: [String: [Template]] = [:]
    private static let lock = NSLock()

    public static func formatFor(_ orientation: String) throws -> AlbumFormat {
        guard let fmt = formats[orientation] else {
            throw AilbumError.invalid("Неизвестная ориентация: \(orientation)")
        }
        return fmt
    }

    public static func templatesFor(_ orientation: String, photoCount: Int? = nil) throws -> [Template] {
        let templates = try catalog(orientation)
        guard let photoCount else { return templates }
        return templates.filter { $0.photoCount == photoCount }
    }

    private static func catalog(_ orientation: String) throws -> [Template] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[orientation] { return hit }
        let fmt = try formatFor(orientation)
        var entries = verticalEntries + fewEntries
        if orientation == "horizontal" {
            entries = entries.map { $0.id == "grid_2x2" ? row4 : $0.id == "grid_65_35" ? page3 : $0 }
        }
        for (id, page) in pageLayouts + [pinwheelInset] {
            // Landscape pages get the portrait design turned on its side.
            let tree = orientation == "horizontal" ? transpose(page) : page
            entries.append(Entry(id: id, tree: pages(c, tree), inset: 0, mirrored: true))
        }
        var result: [Template] = []
        for e in entries {
            let base = build(e, fmt)
            result.append(base)
            if e.mirrored { result.append(mirror(base, fmt)) }
        }
        cache[orientation] = result
        return result
    }

    private typealias Box = (Double, Double, Double, Double)
    // Side kinds: "edge" touches the trim, "cut" borders another cell, "inset" is a margin.
    private typealias Sides = (String, String, String, String)

    private static func build(_ e: Entry, _ fmt: AlbumFormat) -> Template {
        let bleed = fmt.bleedMm
        let box: Box = (
            bleed + e.inset, bleed + e.inset,
            fmt.spreadWmm - bleed - e.inset, fmt.spreadHmm - bleed - e.inset
        )
        var leaves: [(Box, Sides)] = []
        let outer = e.inset != 0 ? "inset" : "edge"
        split(e.tree, box, (outer, outer, outer, outer), &leaves)
        let cells = leaves.enumerated().map { makeCell($0.offset, $0.element.0, $0.element.1, fmt) }
        return Template(id: e.id, photoCount: cells.count, orientation: fmt.orientation, cells: cells)
    }

    private static func split(_ node: Node, _ box: Box, _ sides: Sides, _ leaves: inout [(Box, Sides)]) {
        switch node {
        case .cell:
            leaves.append((box, sides))
        case .inset(let mm, let child):
            let (x0, y0, x1, y1) = box
            split(child, (x0 + mm, y0 + mm, x1 - mm, y1 - mm), ("inset", "inset", "inset", "inset"), &leaves)
        case .cut(let vertical, let cuts, let children):
            let (x0, y0, x1, y1) = box
            let (start, end) = vertical ? (x0, x1) : (y0, y1)
            let bounds = [start] + cuts.map { start + $0 * (end - start) } + [end]
            let last = children.count - 1
            for (i, child) in children.enumerated() {
                let a = bounds[i]
                let b = bounds[i + 1]
                let (left, top, right, bottom) = sides
                if vertical {
                    split(
                        child, (a, y0, b, y1),
                        (i == 0 ? left : "cut", top, i == last ? right : "cut", bottom), &leaves)
                } else {
                    split(
                        child, (x0, a, x1, b),
                        (left, i == 0 ? top : "cut", right, i == last ? bottom : "cut"), &leaves)
                }
            }
        }
    }

    private static func transpose(_ node: Node) -> Node {
        switch node {
        case .cell: return node
        case .inset(let mm, let child): return .inset(mm, transpose(child))
        case .cut(let vertical, let cuts, let children):
            return .cut(vertical: !vertical, cuts, children.map(transpose))
        }
    }

    private static func makeCell(_ index: Int, _ box: Box, _ sides: Sides, _ fmt: AlbumFormat) -> Cell {
        let halfGap = fmt.gapMm / 2
        func shift(_ side: String) -> Double {
            side == "edge" ? fmt.bleedMm : side == "cut" ? -halfGap : 0
        }
        let (bx0, by0, bx1, by1) = box
        let x0 = bx0 - shift(sides.0)
        let y0 = by0 - shift(sides.1)
        let x1 = bx1 + shift(sides.2)
        let y1 = by1 + shift(sides.3)
        let rect = Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        return Cell(index: index, rect: rect, safe: safe(rect, fmt), spineBand: spineBand(rect, fmt))
    }

    private static func safe(_ rect: Rect, _ fmt: AlbumFormat) -> Rect {
        let margin = fmt.bleedMm + fmt.safeMm
        let x0 = max(rect.x, margin)
        let y0 = max(rect.y, margin)
        let x1 = min(rect.x + rect.w, fmt.spreadWmm - margin)
        let y1 = min(rect.y + rect.h, fmt.spreadHmm - margin)
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    private static func spineBand(_ rect: Rect, _ fmt: AlbumFormat) -> Rect? {
        let centre = fmt.spreadWmm / 2
        guard rect.x < centre && centre < rect.x + rect.w else { return nil }
        return Rect(x: centre - fmt.spineGuardMm, y: rect.y, w: 2 * fmt.spineGuardMm, h: rect.h)
    }

    private static func mirror(_ template: Template, _ fmt: AlbumFormat) -> Template {
        func flip(_ r: Rect) -> Rect {
            Rect(x: fmt.spreadWmm - r.x - r.w, y: r.y, w: r.w, h: r.h)
        }
        let cells = template.cells.map {
            Cell(index: $0.index, rect: flip($0.rect), safe: flip($0.safe), spineBand: $0.spineBand.map(flip))
        }
        return Template(
            id: "\(template.id)_m", photoCount: template.photoCount, orientation: template.orientation,
            cells: cells)
    }
}
