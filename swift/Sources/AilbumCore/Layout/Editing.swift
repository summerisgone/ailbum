import Foundation

public enum Editing {
    static let alternativesLimit = 24
    static let unknownWish = "Пожелание не распознано: укажите лица, крупные планы или пейзажи"
    static let aspectTolerance = 0.01
    static let rangeEps = 1e-6

    typealias Detector = (RGBImage) throws -> [DetectedObject]

    /// Test seams standing in for the module-level names Python tests monkeypatch.
    nonisolated(unsafe) static var poolOverride: ((Database, Int, Detector?) throws -> [PhotoFacts])?
    nonisolated(unsafe) static var variantsOverride: (([PhotoFacts], LayoutParams, Int) throws -> [SpreadDraft])?

    private struct SpreadInfo {
        var id: Int
        var layoutId: Int
        var templateId: String
        var storyIds: Set<Int>
        var albumId: Int
        var orientation: String
        var cells: [Int: Cell]
    }

    private struct PlacementRow {
        var cellIndex: Int
        var imageId: Int
        var replacedImageId: Int?
    }

    private struct Where {
        var spreadId: Int
        var position: Int
        var cellIndex: Int
    }

    private struct Pool {
        var photos: [PhotoFacts]
        var byId: [Int: PhotoFacts]
        init(_ photos: [PhotoFacts]) {
            self.photos = photos
            byId = [:]
            // dict(p.image_id: p): a later duplicate replaces the value, keeps the first position.
            for p in photos { byId[p.imageId] = p }
        }
        var values: [PhotoFacts] {
            var seen = Set<Int>()
            var out: [PhotoFacts] = []
            for p in photos where seen.insert(p.imageId).inserted { out.append(byId[p.imageId]!) }
            return out
        }
    }

    // MARK: public API

    public static func alternatives(database: String, spreadId: Int, cellIndex: Int) throws -> [JSONValue] {
        let db = try Database.open(path: database)
        let spread = try spreadInfo(db, spreadId)
        let cell = try cellOf(spread, cellIndex)
        let pool = try loadPool(db, spread.albumId)
        let scoped = pool.values.filter { $0.storyId.map { spread.storyIds.contains($0) } ?? false }
        let placed = try placedMap(db, spread.layoutId)
        let row = try placements(db, spreadId)[cellIndex]
        let unit = row.flatMap { pool.byId[$0.imageId]?.unitKey }
        let source = scoped.isEmpty ? pool.values : scoped
        var found = source.map { (photo: $0, result: Crop.solve(photoAspect: $0.aspect, regions: $0.regions, cell: cell)) }
        found.sort { a, b in
            let ka = -(a.result.fit + (a.photo.selected ? Composer.selectedBonus : 0.0))
            let kb = -(b.result.fit + (b.photo.selected ? Composer.selectedBonus : 0.0))
            if ka != kb { return ka < kb }
            return a.photo.imageId < b.photo.imageId
        }
        return found.prefix(alternativesLimit).map { candidate($0.photo, $0.result, placed, unit) }
    }

    /// The placed photo and its similar siblings, in shooting order.
    public static func similar(database: String, spreadId: Int, cellIndex: Int) throws -> [JSONValue] {
        let db = try Database.open(path: database)
        let spread = try spreadInfo(db, spreadId)
        let cell = try cellOf(spread, cellIndex)
        guard let row = try placements(db, spreadId)[cellIndex] else {
            throw AilbumError.invalid("В ячейке \(cellIndex) нет фото")
        }
        let pool = try loadPool(db, spread.albumId)
        let photo = try photoOf(pool, row.imageId)
        let placed = try placedMap(db, spread.layoutId)
        let members = pool.values.filter { $0.unitKey == photo.unitKey }.sorted { a, b in
            let ka = (a.takenAt == nil, a.takenAt ?? "", a.imageId)
            let kb = (b.takenAt == nil, b.takenAt ?? "", b.imageId)
            if ka.0 != kb.0 { return !ka.0 }
            if ka.1 != kb.1 { return ka.1.utf8.lexicographicallyPrecedes(kb.1.utf8) }
            return ka.2 < kb.2
        }
        return members.map {
            candidate($0, Crop.solve(photoAspect: $0.aspect, regions: $0.regions, cell: cell), placed, photo.unitKey)
        }
    }

    /// Other templates for the same photos, then with one free photo more and one less.
    public static func variants(database: String, spreadId: Int) throws -> [JSONValue] {
        let db = try Database.open(path: database)
        let spread = try spreadInfo(db, spreadId)
        let pool = try loadPool(db, spread.albumId)
        let current = try placements(db, spreadId)
        let photos = try current.keys.sorted().map { try photoOf(pool, current[$0]!.imageId) }
        var sets = [photos]
        let free = try freePhotos(db, spread, pool)
        if !free.isEmpty && photos.count < Composer.maxCells {
            let best = free.reduce(free[0]) { held, p in rankKeyGreater(p, held) ? p : held }
            sets.append(photos + [best])
        }
        if photos.count > 1 {
            let weakest = photos.reduce(photos[0]) { held, p in rankKeyGreater(held, p) ? p : held }
            sets.append(photos.filter { $0.imageId != weakest.imageId })
        }
        let format = try Templates.formatFor(spread.orientation)
        var templates: [String: Template] = [:]
        for t in try Templates.templatesFor(spread.orientation) { templates[t.id] = t }
        var found: [JSONValue] = []
        for (position, photoSet) in sets.enumerated() {
            let params = LayoutParams(
                orientation: spread.orientation, spreadCount: 1, minPhotos: photoSet.count, maxPhotos: photoSet.count)
            for draft in try bestVariants(photoSet, params, limit: templates.count) {
                if position == 0 && draft.templateId == spread.templateId { continue }
                guard let template = templates[draft.templateId] else {
                    throw AilbumError.invalid("Неизвестный шаблон: \(draft.templateId)")
                }
                found.append(variantJSON(draft, template, format))
            }
        }
        return found
    }

    public static func applyVariant(
        database: String, spreadId: Int, templateId: String, imageIds: [Int]
    ) throws -> JSONValue {
        let db = try Database.open(path: database)
        var result: JSONValue = .null
        try db.transaction {
            let spread = try spreadInfo(db, spreadId)
            try LayoutStore.requireDraft(db, albumId: spread.albumId)
            let pool = try loadPool(db, spread.albumId)
            var seen = Set<Int>()
            let ids = imageIds.filter { seen.insert($0).inserted }
            if !(1...Composer.maxCells).contains(ids.count) {
                throw AilbumError.invalid("На развороте может быть от 1 до \(Composer.maxCells) фото")
            }
            let photos = try ids.map { try photoOf(pool, $0) }
            let busy = try placedMap(db, spread.layoutId).filter { $0.value.spreadId != spreadId }.keys
            if !Set(busy).isDisjoint(with: ids) { throw AilbumError.invalid("Кадр уже стоит на другом развороте") }
            let params = LayoutParams(
                orientation: spread.orientation, spreadCount: 1, minPhotos: photos.count, maxPhotos: photos.count)
            guard let draft = try bestVariants(photos, params, limit: 99).first(where: { $0.templateId == templateId })
            else { throw AilbumError.invalid("Шаблон \(templateId) не подходит для \(photos.count) фото") }
            try writeDraft(db, spread, draft, pool)
            result = try finish(db, spread)
        }
        return result
    }

    public static func parsePrompt(_ prompt: String) -> JSONValue {
        let weights = Preferences.parse(prompt)
        return [
            "weights": .object(weights.mapValues { .double($0) }),
            "labels": .array(Preferences.describe(weights).map { .string($0) }),
        ]
    }

    public static func setPhoto(database: String, spreadId: Int, cellIndex: Int, imageId: Int) throws -> JSONValue {
        let db = try Database.open(path: database)
        var result: JSONValue = .null
        try db.transaction {
            let spread = try spreadInfo(db, spreadId)
            try LayoutStore.requireDraft(db, albumId: spread.albumId)
            _ = try cellOf(spread, cellIndex)
            let pool = try loadPool(db, spread.albumId)
            guard let photo = pool.byId[imageId] else {
                throw AilbumError.invalid("Кадр \(imageId) недоступен для раскладки")
            }
            let holder = try db.query(
                "SELECT p.spread_id, p.cell_index FROM layout_placements p"
                    + " JOIN layout_spreads s ON s.id = p.spread_id"
                    + " WHERE s.layout_id = ? AND p.image_id = ?",
                [.integer(spread.layoutId), .integer(imageId)]).first
            if let holder {
                let holderSpread = int(holder["spread_id"]) ?? 0, holderCell = int(holder["cell_index"]) ?? 0
                if holderSpread != spreadId || holderCell != cellIndex {
                    try swap(db, spread, cellIndex, try spreadInfo(db, holderSpread), holderCell, pool)
                }
            } else {
                try place(db, spread, cellIndex, photo, pool)
            }
            result = try finish(db, spread)
        }
        return result
    }

    public static func swapCells(database: String, spreadId: Int, cellA: Int, cellB: Int) throws -> JSONValue {
        let db = try Database.open(path: database)
        var result: JSONValue = .null
        try db.transaction {
            let spread = try spreadInfo(db, spreadId)
            try LayoutStore.requireDraft(db, albumId: spread.albumId)
            _ = try cellOf(spread, cellA)
            _ = try cellOf(spread, cellB)
            if cellA != cellB {
                try swap(db, spread, cellA, spread, cellB, try loadPool(db, spread.albumId))
            }
            result = try finish(db, spread)
        }
        return result
    }

    public static func setTemplate(database: String, spreadId: Int, templateId: String) throws -> JSONValue {
        let db = try Database.open(path: database)
        var result: JSONValue = .null
        try db.transaction {
            var spread = try spreadInfo(db, spreadId)
            try LayoutStore.requireDraft(db, albumId: spread.albumId)
            guard let template = try Templates.templatesFor(spread.orientation).first(where: { $0.id == templateId })
            else { throw AilbumError.invalid("Неизвестный шаблон: \(templateId)") }
            let current = try placements(db, spreadId)
            if template.photoCount != current.count {
                throw AilbumError.invalid(
                    "Шаблон \(templateId) рассчитан на \(template.photoCount) фото, в развороте \(current.count)")
            }
            let pool = try loadPool(db, spread.albumId)
            let photos = try current.keys.sorted().map { try photoOf(pool, current[$0]!.imageId) }
            var results: [[Int]: CropResult] = [:]
            for p in photos {
                for c in template.cells {
                    results[[p.imageId, c.index]] = Crop.solve(photoAspect: p.aspect, regions: p.regions, cell: c)
                }
            }
            let areas = template.cells.map { $0.rect.w * $0.rect.h }
            func total(_ order: [Int]) -> Double {
                var sum = 0.0
                for i in 0..<photos.count { sum += areas[i] * results[[photos[order[i]].imageId, i]]!.fit }
                return sum
            }
            // Lexicographic permutations like itertools; ties keep the earliest.
            var order = Array(0..<photos.count)
            var best = order
            var bestTotal = total(order)
            while nextPermutation(&order) {
                let value = total(order)
                if value > bestTotal { bestTotal = value; best = order }
            }
            try db.execute(
                "UPDATE layout_spreads SET template_id = ? WHERE id = ?", [.text(templateId), .integer(spreadId)])
            spread = try spreadInfo(db, spreadId)
            for (index, photoPos) in best.enumerated() {
                let photo = photos[photoPos]
                try place(db, spread, index, photo, pool, results[[photo.imageId, index]])
            }
            result = try finish(db, spread)
        }
        return result
    }

    public static func setCrop(database: String, spreadId: Int, cellIndex: Int, crop: JSONValue) throws -> JSONValue {
        let db = try Database.open(path: database)
        var result: JSONValue = .null
        try db.transaction {
            let spread = try spreadInfo(db, spreadId)
            try LayoutStore.requireDraft(db, albumId: spread.albumId)
            let cell = try cellOf(spread, cellIndex)
            guard let row = try placements(db, spreadId)[cellIndex] else {
                throw AilbumError.invalid("В ячейке \(cellIndex) нет фото")
            }
            let photo = try photoOf(try loadPool(db, spread.albumId), row.imageId)
            let rect = try validatedWindow(crop, photo.aspect, cell)
            let evaluated = Crop.evaluate(rect: rect, photoAspect: photo.aspect, regions: photo.regions, cell: cell)
            try write(db, spreadId, cellIndex, row.imageId, evaluated, row.replacedImageId)
            result = try finish(db, spread)
        }
        return result
    }

    /// Without a wish the same photos get the best template; a wish re-picks them.
    public static func recomposeSpread(database: String, spreadId: Int, prompt: String = "") throws -> JSONValue {
        let weights = Preferences.parse(prompt)
        if !LayoutAssistant.pyStrip(prompt).isEmpty && weights.isEmpty {
            throw AilbumError.invalid(unknownWish)
        }
        let db = try Database.open(path: database)
        var result: JSONValue = .null
        try db.transaction {
            let spread = try spreadInfo(db, spreadId)
            try LayoutStore.requireDraft(db, albumId: spread.albumId)
            let current = try placements(db, spreadId)
            let pool = try loadPool(db, spread.albumId)
            var photos = try current.keys.sorted().map { try photoOf(pool, current[$0]!.imageId) }
            if !weights.isEmpty { photos = pick(photos, try freePhotos(db, spread, pool), weights) }
            let params = LayoutParams(
                orientation: spread.orientation, spreadCount: 1, minPhotos: photos.count, maxPhotos: photos.count)
            guard let draft = try bestVariants(photos, params, limit: 1).first else {
                throw AilbumError.invalid("Не удалось перекомпоновать разворот")
            }
            try writeDraft(db, spread, draft, pool)
            result = try finish(db, spread)
        }
        return result
    }

    // MARK: helpers

    private static func bestVariants(_ photos: [PhotoFacts], _ params: LayoutParams, limit: Int) throws -> [SpreadDraft] {
        if let variantsOverride { return try variantsOverride(photos, params, limit) }
        return try Composer.bestVariants(photos, params: params, limit: limit)
    }

    /// Python `(a.rank, -a.image_id) > (b.rank, -b.image_id)`.
    private static func rankKeyGreater(_ a: PhotoFacts, _ b: PhotoFacts) -> Bool {
        if a.rank != b.rank { return a.rank > b.rank }
        return -a.imageId > -b.imageId
    }

    private static func nextPermutation(_ a: inout [Int]) -> Bool {
        var i = a.count - 2
        while i >= 0 && a[i] >= a[i + 1] { i -= 1 }
        if i < 0 { return false }
        var j = a.count - 1
        while a[j] <= a[i] { j -= 1 }
        a.swapAt(i, j)
        a[(i + 1)...].reverse()
        return true
    }

    /// Same count of units, best member of each by rank adjusted to the wish.
    private static func pick(_ photos: [PhotoFacts], _ free: [PhotoFacts], _ weights: [String: Double]) -> [PhotoFacts] {
        var best: [String: PhotoFacts] = [:]
        for photo in Preferences.apply(photos + free, weights) {
            if let held = best[photo.unitKey], !rankKeyGreater(photo, held) { continue }
            best[photo.unitKey] = photo
        }
        let ranked = best.values.sorted { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            return a.imageId < b.imageId
        }
        return Array(ranked.prefix(photos.count))
    }

    /// Pool photos of the spread's stories whose similar group is not on the layout yet.
    private static func freePhotos(_ db: Database, _ spread: SpreadInfo, _ pool: Pool) throws -> [PhotoFacts] {
        let used = Set(try placedMap(db, spread.layoutId).keys.compactMap { pool.byId[$0]?.unitKey })
        return pool.values.filter { p in
            (p.storyId.map { spread.storyIds.contains($0) } ?? false) && !used.contains(p.unitKey)
        }
    }

    private static func placedMap(_ db: Database, _ layoutId: Int) throws -> [Int: Where] {
        let rows = try db.query(
            "SELECT p.image_id, p.spread_id, p.cell_index, s.position FROM layout_placements p"
                + " JOIN layout_spreads s ON s.id = p.spread_id WHERE s.layout_id = ?",
            [.integer(layoutId)])
        var out: [Int: Where] = [:]
        for row in rows {
            out[int(row["image_id"]) ?? 0] = Where(
                spreadId: int(row["spread_id"]) ?? 0, position: int(row["position"]) ?? 0,
                cellIndex: int(row["cell_index"]) ?? 0)
        }
        return out
    }

    private static func candidate(
        _ photo: PhotoFacts, _ result: CropResult, _ placed: [Int: Where], _ unitKey: String?
    ) -> JSONValue {
        let location: JSONValue = placed[photo.imageId].map {
            ["spread_id": .int($0.spreadId), "position": .int($0.position), "cell_index": .int($0.cellIndex)]
        } ?? .null
        return [
            "image_id": .int(photo.imageId),
            "fit": .double(result.fit),
            "warnings": .array(result.violations.map { .string($0) }),
            "in_selection": .bool(photo.selected),
            "placed": location,
            "similar": .bool(unitKey != nil && photo.unitKey == unitKey),
        ]
    }

    private static func variantJSON(_ draft: SpreadDraft, _ template: Template, _ format: AlbumFormat) -> JSONValue {
        var cells: [Int: Cell] = [:]
        for c in template.cells { cells[c.index] = c }
        let placements = draft.placements.sorted { $0.cellIndex < $1.cellIndex }
        return [
            "template_id": .string(draft.templateId),
            "score": .double(draft.score),
            "image_ids": .array(draft.placements.map(\.imageId).sorted().map { .int($0) }),
            "cells": .array(placements.map { p in
                let cell = cells[p.cellIndex]!
                return [
                    "index": .int(p.cellIndex),
                    "x": .double(cell.rect.x / format.spreadWmm),
                    "y": .double(cell.rect.y / format.spreadHmm),
                    "w": .double(cell.rect.w / format.spreadWmm),
                    "h": .double(cell.rect.h / format.spreadHmm),
                    "image_id": .int(p.imageId),
                    "crop": ["x": .double(p.crop.x), "y": .double(p.crop.y), "w": .double(p.crop.w), "h": .double(p.crop.h)],
                ]
            }),
        ]
    }

    /// Replace the spread's template and photos; dropped photos go to the unplaced list.
    private static func writeDraft(_ db: Database, _ spread: SpreadInfo, _ draft: SpreadDraft, _ pool: Pool) throws {
        let before = Set(try placements(db, spread.id).values.map(\.imageId))
        try db.execute(
            "UPDATE layout_spreads SET template_id = ?, warnings_json = ?, assistant_reason = NULL WHERE id = ?",
            [.text(draft.templateId), .text(dumpStrings(draft.warnings)), .integer(spread.id)])
        try db.execute("DELETE FROM layout_placements WHERE spread_id = ?", [.integer(spread.id)])
        for item in draft.placements {
            let replaced = pool.byId[item.imageId].map { replacedFor($0, pool) } ?? item.replacedImageId
            try db.execute(
                "INSERT INTO layout_placements (spread_id, cell_index, image_id, crop_x, crop_y,"
                    + " crop_w, crop_h, fit, warnings_json, replaced_image_id)"
                    + " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.integer(spread.id), .integer(item.cellIndex), .integer(item.imageId), .real(item.crop.x),
                 .real(item.crop.y), .real(item.crop.w), .real(item.crop.h), .real(item.fit),
                 .text(dumpStrings(item.warnings)), replaced.map { .integer($0) } ?? .null])
        }
        let placed = try placedMap(db, spread.layoutId)
        let row = try db.query("SELECT unplaced_json FROM layouts WHERE id = ?", [.integer(spread.layoutId)]).first
        var unplaced = (try JSONValue.parse(text(row?["unplaced_json"]) ?? "[]").arrayValue ?? [])
            .filter { !placed.keys.contains($0["image_id"]?.intValue ?? Int.min) }
        let known = Set(unplaced.compactMap { $0["image_id"]?.intValue })
        for id in before.sorted() where placed[id] == nil && !known.contains(id) {
            unplaced.append(["image_id": .int(id), "reason": "removed"])
        }
        try db.execute(
            "UPDATE layouts SET unplaced_json = ? WHERE id = ?",
            [.text(LayoutStore.dumps(.array(unplaced))), .integer(spread.layoutId)])
    }

    private static func spreadInfo(_ db: Database, _ spreadId: Int) throws -> SpreadInfo {
        let row = try db.query(
            "SELECT s.id, s.layout_id, s.template_id, s.story_ids_json, l.album_id, l.run_id, l.orientation"
                + " FROM layout_spreads s JOIN layouts l ON l.id = s.layout_id WHERE s.id = ?",
            [.integer(spreadId)]).first
        guard let row else { throw AilbumError.invalid("Разворот \(spreadId) не найден") }
        let orientation = text(row["orientation"]) ?? ""
        let templateId = text(row["template_id"]) ?? ""
        let stories = try JSONValue.parse(text(row["story_ids_json"]) ?? "[]").arrayValue ?? []
        guard let template = try Templates.templatesFor(orientation).first(where: { $0.id == templateId }) else {
            throw AilbumError.invalid("Неизвестный шаблон: \(templateId)")
        }
        var cells: [Int: Cell] = [:]
        for c in template.cells { cells[c.index] = c }
        return SpreadInfo(
            id: int(row["id"]) ?? 0, layoutId: int(row["layout_id"]) ?? 0, templateId: templateId,
            storyIds: Set(stories.compactMap(\.intValue)), albumId: int(row["album_id"]) ?? 0,
            orientation: orientation, cells: cells)
    }

    private static func cellOf(_ spread: SpreadInfo, _ cellIndex: Int) throws -> Cell {
        guard let cell = spread.cells[cellIndex] else { throw AilbumError.invalid("Ячейка \(cellIndex) не найдена") }
        return cell
    }

    private static func placements(_ db: Database, _ spreadId: Int) throws -> [Int: PlacementRow] {
        var out: [Int: PlacementRow] = [:]
        for row in try db.query("SELECT * FROM layout_placements WHERE spread_id = ?", [.integer(spreadId)]) {
            let index = int(row["cell_index"]) ?? 0
            out[index] = PlacementRow(
                cellIndex: index, imageId: int(row["image_id"]) ?? 0, replacedImageId: int(row["replaced_image_id"]))
        }
        return out
    }

    private static func loadPool(_ db: Database, _ albumId: Int) throws -> Pool {
        // detector nil reads cached scans only, so edits never rerun or drop them.
        if let poolOverride { return Pool(try poolOverride(db, albumId, nil)) }
        return Pool(try Facts.loadPool(db, albumId: albumId, detector: nil, progress: nil))
    }

    private static func photoOf(_ pool: Pool, _ imageId: Int) throws -> PhotoFacts {
        guard let photo = pool.byId[imageId] else {
            throw AilbumError.invalid("Кадр \(imageId) недоступен для раскладки")
        }
        return photo
    }

    private static func replacedFor(_ photo: PhotoFacts, _ pool: Pool) -> Int? {
        if photo.selected { return nil }
        return pool.values.filter { $0.unitKey == photo.unitKey && $0.selected }.map(\.imageId).min()
    }

    private static func place(
        _ db: Database, _ spread: SpreadInfo, _ cellIndex: Int, _ photo: PhotoFacts, _ pool: Pool,
        _ given: CropResult? = nil
    ) throws {
        let result = try given ?? Crop.solve(photoAspect: photo.aspect, regions: photo.regions, cell: cellOf(spread, cellIndex))
        try write(db, spread.id, cellIndex, photo.imageId, result, replacedFor(photo, pool))
    }

    private static func swap(
        _ db: Database, _ spreadA: SpreadInfo, _ cellA: Int, _ spreadB: SpreadInfo, _ cellB: Int, _ pool: Pool
    ) throws {
        guard let rowA = try placements(db, spreadA.id)[cellA], let rowB = try placements(db, spreadB.id)[cellB] else {
            throw AilbumError.invalid("В ячейке нет фото")
        }
        let photoA = try photoOf(pool, rowA.imageId)
        let photoB = try photoOf(pool, rowB.imageId)
        try place(db, spreadA, cellA, photoB, pool)
        try place(db, spreadB, cellB, photoA, pool)
    }

    private static func write(
        _ db: Database, _ spreadId: Int, _ cellIndex: Int, _ imageId: Int, _ result: CropResult, _ replaced: Int?
    ) throws {
        let rect = result.rect
        try db.execute(
            "UPDATE layout_placements SET image_id = ?, crop_x = ?, crop_y = ?, crop_w = ?,"
                + " crop_h = ?, fit = ?, warnings_json = ?, replaced_image_id = ?"
                + " WHERE spread_id = ? AND cell_index = ?",
            [.integer(imageId), .real(rect.x), .real(rect.y), .real(rect.w), .real(rect.h), .real(result.fit),
             .text(dumpStrings(result.violations)), replaced.map { .integer($0) } ?? .null,
             .integer(spreadId), .integer(cellIndex)])
    }

    /// Python `float(value)` for JSON-like values; nil where Python raises.
    private static func pyFloat(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let v)?: return Double(v)
        case .double(let v)?: return v
        case .bool(let v)?: return v ? 1.0 : 0.0
        case .string(let s)?:
            // Swift also parses hex floats; Python float() does not.
            let t = LayoutAssistant.pyStrip(s)
            return t.contains(where: { $0 == "x" || $0 == "X" }) ? nil : Double(t)
        default: return nil
        }
    }

    private static func validatedWindow(_ crop: JSONValue, _ photoAspect: Double, _ cell: Cell) throws -> Rect {
        var values: [Double] = []
        for key in ["x", "y", "w", "h"] {
            guard let v = pyFloat(crop[key]) else { throw AilbumError.invalid("Кроп должен содержать числа x, y, w, h") }
            values.append(v)
        }
        let (x, y, w, h) = (values[0], values[1], values[2], values[3])
        if !values.allSatisfy({ $0.isFinite }) { throw AilbumError.invalid("Кроп должен содержать конечные числа") }
        if w <= 0 || h <= 0 || x < -rangeEps || y < -rangeEps {
            throw AilbumError.invalid("Кроп выходит за пределы кадра")
        }
        if x + w > 1 + rangeEps || y + h > 1 + rangeEps { throw AilbumError.invalid("Кроп выходит за пределы кадра") }
        let windowAspect = w * photoAspect / h
        let cellAspect = cell.rect.w / cell.rect.h
        if abs(windowAspect / cellAspect - 1) > aspectTolerance {
            throw AilbumError.invalid("Пропорции кропа не совпадают с ячейкой")
        }
        return Rect(x: max(x, 0.0), y: max(y, 0.0), w: w, h: h)
    }

    private static func finish(_ db: Database, _ spread: SpreadInfo) throws -> JSONValue {
        var now = Catalog.utcNow()
        if let dot = now.firstIndex(of: ".") { now = String(now[..<dot]) + "+00:00" }
        try db.execute("UPDATE layouts SET updated_at = ? WHERE id = ?", [.text(now), .integer(spread.layoutId)])
        guard let layout = try LayoutStore.loadLayout(db, albumId: spread.albumId) else {
            throw AilbumError.invalid("Раскладка не найдена")
        }
        return layout
    }

    private static func dumpStrings(_ items: [String]) -> String {
        LayoutStore.dumps(.array(items.map { .string($0) }))
    }

    private static func text(_ v: SQLValue?) -> String? { if case .text(let s)? = v { return s } else { return nil } }

    private static func int(_ v: SQLValue?) -> Int? { if case .integer(let i)? = v { return Int(i) } else { return nil } }
}
