import Foundation

public struct ComposedGroup: Equatable {
    public var spreads: [SpreadDraft]
    public var unplaced: [JSONValue]

    public init(spreads: [SpreadDraft], unplaced: [JSONValue]) {
        self.spreads = spreads
        self.unplaced = unplaced
    }
}

public enum Composer {
    public static let selectedBonus = 0.15
    static let rankWeight = 0.25
    static let repeatCost = 0.15
    static let underfillCost = 1000.0
    public static let maxCells = 8

    // MARK: cache keys

    private struct CellKey: Hashable {
        var index: Int
        var rect: [Double]
        var safe: [Double]
        var band: [Double]?

        init(_ cell: Cell) {
            index = cell.index
            rect = [cell.rect.x, cell.rect.y, cell.rect.w, cell.rect.h]
            safe = [cell.safe.x, cell.safe.y, cell.safe.w, cell.safe.h]
            band = cell.spineBand.map { [$0.x, $0.y, $0.w, $0.h] }
        }
    }

    private struct RegionKey: Hashable {
        var box: [Double]
        var weight: Double
        var hard: Bool
        var kind: String
    }

    private struct CropKey: Hashable {
        var aspect: Double
        var regions: [RegionKey]
        var cell: CellKey
    }

    nonisolated(unsafe) private static var cropCache: [CropKey: CropResult] = [:]
    private static let cropLock = NSLock()

    private static func crop(_ aspect: Double, _ regions: [Region], _ cell: Cell) -> CropResult {
        let key = CropKey(
            aspect: aspect,
            regions: regions.map {
                RegionKey(
                    box: [$0.bbox.x, $0.bbox.y, $0.bbox.w, $0.bbox.h], weight: $0.weight,
                    hard: $0.hard, kind: $0.kind)
            },
            cell: CellKey(cell))
        cropLock.lock()
        if let hit = cropCache[key] {
            cropLock.unlock()
            return hit
        }
        cropLock.unlock()
        let result = Crop.solve(photoAspect: aspect, regions: regions, cell: cell)
        cropLock.lock()
        if cropCache.count >= 65536 { cropCache.removeAll() }
        cropCache[key] = result
        cropLock.unlock()
        return result
    }

    // MARK: units

    private struct TimeKey {
        var missing: Bool
        var time: String
        var imageId: Int

        func precedes(_ other: TimeKey) -> Bool {
            if missing != other.missing { return !missing }
            if time != other.time { return time.utf8.lexicographicallyPrecedes(other.time.utf8) }
            return imageId < other.imageId
        }
    }

    private static func keyOf(_ photo: PhotoFacts) -> TimeKey {
        TimeKey(missing: photo.takenAt == nil, time: photo.takenAt ?? "", imageId: photo.imageId)
    }

    private struct Unit {
        var members: [PhotoFacts]
        var rank: Double
        var timeKey: TimeKey

        init(_ members: [PhotoFacts]) {
            self.members = members.sorted { $0.imageId < $1.imageId }
            rank = self.members.map(\.rank).max()!
            var best = Composer.keyOf(self.members[0])
            for p in self.members.dropFirst() {
                let k = Composer.keyOf(p)
                if k.precedes(best) { best = k }
            }
            timeKey = best
        }

        func replacedFor(_ placed: PhotoFacts) -> Int? {
            if placed.selected { return nil }
            return members.first(where: \.selected)?.imageId
        }
    }

    /// Units by similar group; with `splitSelected` each selected member of a group stands alone.
    private static func makeUnits(
        _ photos: [PhotoFacts], perPhoto: Bool, splitSelected: Bool = false
    ) -> [Unit] {
        var order: [String] = []
        var groups: [String: [PhotoFacts]] = [:]
        var lead: [String: Int] = [:]
        if splitSelected {
            for photo in photos where photo.selected {
                lead[photo.unitKey] = min(lead[photo.unitKey] ?? photo.imageId, photo.imageId)
            }
        }
        for photo in photos {
            let key: String
            if perPhoto {
                key = "photo:\(photo.imageId)"
            } else if splitSelected && photo.selected {
                key = "\(photo.unitKey)#\(photo.imageId)"
            } else if splitSelected, let first = lead[photo.unitKey] {
                key = "\(photo.unitKey)#\(first)"
            } else {
                key = photo.unitKey
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(photo)
        }
        let units = order.map { Unit(groups[$0]!) }
        return units.enumerated().sorted {
            $0.element.timeKey.precedes($1.element.timeKey)
                || (!$1.element.timeKey.precedes($0.element.timeKey) && $0.offset < $1.offset)
        }.map(\.element)
    }

    // MARK: filler

    private struct BestKey: Hashable {
        var unit: Int
        var cell: CellKey
    }

    private struct Best {
        var score: Double
        var photo: PhotoFacts
        var result: CropResult
    }

    private final class Filler {
        let units: [Unit]
        private var cells: [BestKey: Best] = [:]

        init(_ units: [Unit]) { self.units = units }

        func best(_ unitIndex: Int, _ cell: Cell) -> Best {
            let key = BestKey(unit: unitIndex, cell: CellKey(cell))
            if let found = cells[key] { return found }
            var best: Best?
            for photo in units[unitIndex].members {
                let result = Composer.crop(photo.aspect, photo.regions, cell)
                let fit = result.fit + (photo.selected ? Composer.selectedBonus : 0.0)
                let score = fit + Composer.rankWeight * photo.rank
                if best == nil || score > best!.score {
                    best = Best(score: score, photo: photo, result: result)
                }
            }
            cells[key] = best!
            return best!
        }

        /// (value, [(cell, unitIndex)]) maximising the area-weighted score.
        func fill(_ indexes: [Int], _ template: Template) -> (Double, [(Cell, Int)]) {
            let cells = template.cells
            var total = 0.0
            for c in cells { total += c.rect.w * c.rect.h }
            let n = cells.count
            let values: [[Double]] = indexes.map { u in
                cells.map { c in best(u, c).score * c.rect.w * c.rect.h / total }
            }
            let size = 1 << n
            var bestValue = [Double](repeating: -Double.infinity, count: size)
            var pick = [Int](repeating: 0, count: size)
            bestValue[0] = 0.0
            if size > 1 {
                for mask in 1..<size {
                    let column = mask.nonzeroBitCount - 1
                    for u in 0..<n where (mask >> u) & 1 == 1 {
                        let value = bestValue[mask ^ (1 << u)] + values[u][column]
                        if value > bestValue[mask] {
                            bestValue[mask] = value
                            pick[mask] = u
                        }
                    }
                }
            }
            var mask = size - 1
            var assignment: [(Cell, Int)] = []
            for column in stride(from: n - 1, through: 0, by: -1) {
                let u = pick[mask]
                assignment.append((cells[column], indexes[u]))
                mask ^= 1 << u
            }
            assignment.reverse()
            return (bestValue[size - 1], assignment)
        }

        func draft(
            _ template: Template, _ value: Double, _ assignment: [(Cell, Int)], storyIds: [Int],
            warnings: [String]
        ) -> SpreadDraft {
            var placements: [PlacementDraft] = []
            for (cell, unitIndex) in assignment {
                let b = best(unitIndex, cell)
                placements.append(
                    PlacementDraft(
                        cellIndex: cell.index, imageId: b.photo.imageId, crop: b.result.rect,
                        fit: b.result.fit, warnings: b.result.violations,
                        replacedImageId: units[unitIndex].replacedFor(b.photo)))
            }
            return SpreadDraft(
                templateId: template.id, storyIds: storyIds, placements: placements, score: value,
                warnings: warnings)
        }
    }

    // MARK: public API

    /// Best draft per template for exactly these photos, one cell each.
    public static func bestVariants(
        _ photos: [PhotoFacts], params: LayoutParams, limit: Int = 3
    ) throws -> [SpreadDraft] {
        let units = makeUnits(photos, perPhoto: true)
        if !(1...maxCells).contains(units.count) || limit < 1 { return [] }
        let filler = Filler(units)
        let indexes = Array(0..<units.count)
        var drafts: [SpreadDraft] = []
        for template in try Templates.templatesFor(params.orientation, photoCount: units.count) {
            let (value, assignment) = filler.fill(indexes, template)
            drafts.append(filler.draft(template, value, assignment, storyIds: [], warnings: []))
        }
        let sorted = drafts.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            if a.element.templateId != b.element.templateId {
                return a.element.templateId.utf8.lexicographicallyPrecedes(b.element.templateId.utf8)
            }
            return a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(limit))
    }

    public static func composeGroup(
        _ photos: [PhotoFacts], allocation: Allocation, params: LayoutParams
    ) throws -> ComposedGroup {
        var units = makeUnits(photos, perPhoto: false)
        if units.isEmpty { return ComposedGroup(spreads: [], unplaced: []) }
        let minP = max(1, min(maxCells, params.minPhotos))
        let maxP = max(1, min(maxCells, params.maxPhotos))
        let spreadsWanted = max(1, allocation.spreads)
        if units.count < spreadsWanted * minP {
            units = makeUnits(photos, perPhoto: false, splitSelected: true)
        }

        var unplaced: [(Int, JSONValue)] = []
        let overflow = units.count - spreadsWanted * maxP
        if overflow > 0 {
            let order = units.indices.sorted { a, b in
                if units[a].rank != units[b].rank { return units[a].rank < units[b].rank }
                let fa = -units[a].members[0].imageId
                let fb = -units[b].members[0].imageId
                if fa != fb { return fa < fb }
                return a < b
            }
            let dropped = Set(order.prefix(overflow))
            for index in order.prefix(overflow) {
                var keeper = units[index].members[0]
                for p in units[index].members.dropFirst() {
                    // max(key=(selected, rank, -image_id)), first maximum wins
                    let better: Bool
                    if p.selected != keeper.selected {
                        better = p.selected
                    } else if p.rank != keeper.rank {
                        better = p.rank > keeper.rank
                    } else {
                        better = -p.imageId > -keeper.imageId
                    }
                    if better { keeper = p }
                }
                unplaced.append(
                    (
                        keeper.imageId,
                        .object(["image_id": .int(keeper.imageId), "reason": .string("capacity")])
                    ))
            }
            unplaced.sort { $0.0 < $1.0 }
            units = units.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        }

        let chunks = try partition(
            units, count: min(spreadsWanted, units.count), minP: minP, maxP: maxP,
            orientation: params.orientation)
        var drafts: [SpreadDraft] = []
        for chunk in chunks {
            var warnings: [String] = []
            if chunk.size < minP { warnings.append("underfilled") }
            if allocation.merged { warnings.append("merged_stories") }
            drafts.append(
                chunk.filler.draft(
                    chunk.template, chunk.value, chunk.assignment, storyIds: allocation.storyIds,
                    warnings: warnings))
        }
        var byId: [Int: PhotoFacts] = [:]
        for p in photos { byId[p.imageId] = p }
        return ComposedGroup(
            spreads: try drafts.map { try withAlternatives($0, byId, params) },
            unplaced: unplaced.map(\.1))
    }

    private static func withAlternatives(
        _ draft: SpreadDraft, _ byId: [Int: PhotoFacts], _ params: LayoutParams
    ) throws -> SpreadDraft {
        let photos = draft.placements.map { byId[$0.imageId]! }
        var replaced: [Int: Int?] = [:]
        for p in draft.placements { replaced[p.imageId] = p.replacedImageId }
        let others = try bestVariants(photos, params: params, limit: maxCells * 4)
            .filter { $0.templateId != draft.templateId }.prefix(2)
        var result = draft
        result.alternatives = others.map { v in
            var alt = v
            alt.storyIds = draft.storyIds
            alt.warnings = draft.warnings
            alt.placements = v.placements.map { p in
                var q = p
                q.replacedImageId = replaced[p.imageId] ?? nil
                return q
            }
            return alt
        }
        return result
    }

    // MARK: partition

    private struct Chunk {
        var filler: Filler
        var template: Template
        var value: Double
        var assignment: [(Cell, Int)]
        var size: Int
    }

    private struct State: Hashable {
        var done: Int
        var last: String?
    }

    private struct Link {
        var total: Double
        var previous: (Int, State)?
        var chunk: (Template, Double, [(Cell, Int)], Int)?
    }

    /// Insertion-ordered dictionary, as Python dicts iterate.
    private struct Layer {
        var keys: [State] = []
        var items: [State: Link] = [:]
    }

    /// Split time-ordered units into `count` consecutive chunks, choosing templates by DP.
    private static func partition(
        _ units: [Unit], count: Int, minP: Int, maxP: Int, orientation: String
    ) throws -> [Chunk] {
        let n = units.count
        let filler = Filler(units)
        var options: [[Int]: [(Template, Double, [(Cell, Int)])]] = [:]

        func chunkOptions(_ start: Int, _ size: Int) throws -> [(Template, Double, [(Cell, Int)])] {
            let key = [start, size]
            if let hit = options[key] { return hit }
            let indexes = Array(start..<(start + size))
            var list: [(Template, Double, [(Cell, Int)])] = []
            for t in try Templates.templatesFor(orientation, photoCount: size) {
                let (value, assignment) = filler.fill(indexes, t)
                list.append((t, value, assignment))
            }
            options[key] = list
            return list
        }

        var layers = [Layer](repeating: Layer(), count: n + 1)
        let root = State(done: 0, last: nil)
        layers[0].keys.append(root)
        layers[0].items[root] = Link(total: 0.0, previous: nil, chunk: nil)
        for i in 0..<n {
            for state in layers[i].keys {
                let base = layers[i].items[state]!.total
                if state.done >= count { continue }
                let left = count - state.done - 1
                for size in 1...min(maxP, n - i) {
                    let rest = n - i - size
                    if rest < left || rest > left * maxP { continue }
                    let penalty = underfillCost * Double(max(0, minP - size))
                    for (template, value, assignment) in try chunkOptions(i, size) {
                        // A mirrored variant still repeats its base template.
                        let shape =
                            template.id.hasSuffix("_m")
                            ? String(template.id.dropLast(2)) : template.id
                        let total =
                            base + value - penalty - (shape == state.last ? repeatCost : 0.0)
                        let key = State(done: state.done + 1, last: shape)
                        let current = layers[i + size].items[key]
                        if current == nil || total > current!.total {
                            if current == nil { layers[i + size].keys.append(key) }
                            layers[i + size].items[key] = Link(
                                total: total, previous: (i, state),
                                chunk: (template, value, assignment, size))
                        }
                    }
                }
            }
        }

        let final = layers[n]
        var bestKey: State?
        for k in final.keys where k.done == count {
            if bestKey == nil || final.items[k]!.total > final.items[bestKey!]!.total {
                bestKey = k
            }
        }
        var chunks: [Chunk] = []
        var position: (Int, State)? = bestKey.map { (n, $0) }
        while let (at, state) = position, at > 0 {
            let link = layers[at].items[state]!
            let (template, value, assignment, size) = link.chunk!
            chunks.append(
                Chunk(
                    filler: filler, template: template, value: value, assignment: assignment,
                    size: size))
            position = link.previous
        }
        chunks.reverse()
        return chunks
    }
}
