import Foundation
import Testing
@testable import AilbumCore

private let editFace = Region(bbox: Rect(x: 0.0, y: 0.3, w: 0.1, h: 0.3), weight: 1.0, hard: true, kind: "face")

private func edPhoto(
    _ id: Int, _ aspect: Double, _ unit: String, selected: Bool = true, regions: [Region] = [],
    rank: Double = 0.5, storyId: Int? = nil
) -> PhotoFacts {
    PhotoFacts(
        imageId: id, aspect: aspect, unitKey: unit, storyId: storyId, takenAt: nil, rank: rank,
        selected: selected, regions: regions)
}

private let editPool: [PhotoFacts] = [
    edPhoto(1, 1.5, "image:1"),
    edPhoto(2, 0.7, "image:2"),
    edPhoto(3, 1.0, "image:3", regions: [editFace]),
    edPhoto(4, 1.4, "image:1", selected: false),  // unselected sibling of 1
    edPhoto(5, 1.2, "image:5"),
]

private let editStoryPool: [PhotoFacts] = [
    edPhoto(1, 1.5, "image:1", storyId: 1),
    edPhoto(2, 0.7, "image:2", storyId: 1),
    edPhoto(3, 1.0, "image:3", regions: [editFace], storyId: 1),
    edPhoto(4, 1.4, "image:1", selected: false, storyId: 1),
    edPhoto(5, 1.2, "image:5", storyId: 1),
]

private let editReal = ProcessInfo.processInfo.environment["SUPERLITE_REAL"] == "1"

private func fakeBestVariants(_ photos: [PhotoFacts], _ params: LayoutParams, _ limit: Int) throws -> [SpreadDraft] {
    let template = try Templates.templatesFor(params.orientation, photoCount: photos.count)[0]
    let ordered = photos.sorted { $0.imageId < $1.imageId }
    var placements: [PlacementDraft] = []
    for (cell, photo) in zip(template.cells, ordered) {
        let crop = Crop.solve(photoAspect: photo.aspect, regions: photo.regions, cell: cell)
        placements.append(PlacementDraft(
            cellIndex: cell.index, imageId: photo.imageId, crop: crop.rect, fit: crop.fit,
            warnings: crop.violations, replacedImageId: nil))
    }
    return [SpreadDraft(templateId: template.id, storyIds: [], placements: placements, score: 0.0, warnings: ["draft"])]
}

private final class DetectorLog: @unchecked Sendable {
    var allNil = true
    var calls = 0
}

private func refused<T>(_ body: () throws -> T) -> String? {
    do {
        _ = try body()
        return nil
    } catch let AilbumError.invalid(message) {
        return message
    } catch {
        return "other: \(error)"
    }
}

private func edNum(_ v: JSONValue?) -> Double { v?.doubleValue ?? .nan }
private func edNear(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 + 1e-6 * abs(b) }

private func edSeedPhoto(_ db: Database, _ root: String, _ photo: PhotoFacts) throws {
    let i = photo.imageId
    let height = photo.regions.isEmpty ? 1000.0 : 1200.0
    let width = Int((photo.aspect * height).rounded(.toNearestOrEven))
    let source = root + "/p\(i).jpg"
    try Data("jpg".utf8).write(to: URL(fileURLWithPath: source))
    try db.execute(
        "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            + " file_size_bytes, modified_at, sha256, width, height, exif_json,"
            + " container_metadata_json, indexed_at)"
            + " VALUES (?, ?, 's', ?, ?, 'jpg', 1, 't', 'x', ?, ?, '{}', '{}', 't')",
        [.integer(i), .text(source), .text("p\(i)"), .text("p\(i)"), .integer(width), .integer(Int(height))])
    let shared = editPool.filter { $0.unitKey == photo.unitKey }.count > 1
    let cluster: SQLValue = shared ? .integer(Int(photo.unitKey.split(separator: ":")[1]) ?? 0) : .null
    try db.execute(
        "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,"
            + " is_blurry, similar_cluster, story_id, selected) VALUES ('r', ?, ?, 1, 1, ?, 0, ?, ?, ?)",
        [.integer(i), .text("p\(i)"), .real(photo.rank), cluster, photo.storyId.map { .integer($0) } ?? .null,
         .integer(photo.selected ? 1 : 0)])
    if photo.selected {
        try db.execute("INSERT INTO album_photos VALUES (1, ?, ?, 't')", [.integer(i), .integer(i)])
    }
    if !photo.regions.isEmpty {
        // build_regions pads this box to FACE: x -0.2w..+1.2w, y -0.35h..+1.15h.
        try db.execute(
            "INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
                + " bbox_width, bbox_height, confidence) VALUES ('r', ?, ?, 0, 0, 444, 100, 240, 1)",
            [.integer(i), .text("f\(i)")])
    }
}

private func edCell(_ templateId: String, _ index: Int) throws -> Cell {
    try #require(try Templates.templatesFor("vertical").first { $0.id == templateId }).cells[index]
}

private func edImages(_ layout: JSONValue) -> [Int] {
    (layout["spreads"]?[0]?["cells"]?.arrayValue ?? []).compactMap { $0["placement"]?["image_id"]?.intValue }
}

private func edCells(_ layout: JSONValue) -> [JSONValue] { layout["spreads"]?[0]?["cells"]?.arrayValue ?? [] }

private func edAspectCrop(_ photoAspect: Double, _ index: Int, _ scale: Double = 1.0) throws -> [String: Double] {
    let c = try edCell("page_2h", index).rect
    let ratio = c.w / c.h
    if ratio / photoAspect <= 1 { return ["x": 0.0, "y": 0.0, "w": ratio / photoAspect * scale, "h": scale] }
    return ["x": 0.0, "y": 0.0, "w": scale, "h": photoAspect / ratio * scale]
}

private func edJSON(_ crop: [String: Double]) -> JSONValue { .object(crop.mapValues { .double($0) }) }

@Suite(.serialized) final class LayoutEditingTests {
    let db: Database
    let path: String
    let root: String
    private let log = DetectorLog()

    init() throws {
        root = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-ed-\(UUID().uuidString)"
        path = root + "/a.db"
        db = try Database.open(path: path)
        try db.execute("INSERT INTO analysis_runs VALUES ('r','s','o','t','t','b','{}','{}','completed')", [])
        try db.execute(
            "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
                + " VALUES (1, 'u1', 'А', 'r', 't', 't')", [])
        for photo in editPool { try edSeedPhoto(db, root, photo) }
        try db.execute(
            "INSERT INTO layouts (id, album_id, run_id, orientation, spread_count, min_photos,"
                + " max_photos, selection_hash, created_at, updated_at)"
                + " VALUES (1,1,'r','vertical',1,3,3,'h','t','t')", [])
        try db.execute("INSERT INTO layout_spreads VALUES (5, 1, 1, 'page_2h', '[1]', '[\"x\"]', 'why')", [])
        let cells = try Templates.templatesFor("vertical", photoCount: 3)[0].cells
        for (index, imageId) in [1, 2, 3].enumerated() {
            let photo = editPool[imageId - 1]
            let r = Crop.solve(photoAspect: photo.aspect, regions: photo.regions, cell: cells[index])
            try db.execute(
                "INSERT INTO layout_placements VALUES (5, ?, ?, ?, ?, ?, ?, ?, '[]', NULL)",
                [.integer(index), .integer(imageId), .real(r.rect.x), .real(r.rect.y), .real(r.rect.w),
                 .real(r.rect.h), .real(r.fit)])
        }
        Editing.poolOverride = nil
        Editing.variantsOverride = nil
        if !editReal {
            let log = log
            Editing.poolOverride = { _, _, detector in
                log.calls += 1
                if detector != nil { log.allNil = false }
                return editPool
            }
            Editing.variantsOverride = fakeBestVariants
        }
    }

    deinit {
        Editing.poolOverride = nil
        Editing.variantsOverride = nil
    }

    private func usePool(_ photos: [PhotoFacts]) { Editing.poolOverride = { _, _, _ in photos } }

    private func unplaced() throws -> JSONValue {
        let row = try db.query("SELECT unplaced_json FROM layouts", []).first
        guard case .text(let raw)? = row?["unplaced_json"] else { return .null }
        return try JSONValue.parse(raw)
    }

    @Test func editingUnknownSpreadRaises() {
        let p = path
        #expect(refused { try Editing.alternatives(database: p, spreadId: 99, cellIndex: 0) } == "Разворот 99 не найден")
        #expect(refused { try Editing.setPhoto(database: p, spreadId: 99, cellIndex: 0, imageId: 1) } != nil)
        #expect(refused { try Editing.swapCells(database: p, spreadId: 99, cellA: 0, cellB: 1) } != nil)
        #expect(refused { try Editing.setTemplate(database: p, spreadId: 99, templateId: "pages") } != nil)
        #expect(refused {
            try Editing.setCrop(
                database: p, spreadId: 99, cellIndex: 0, crop: edJSON(["x": 0, "y": 0, "w": 1, "h": 1]))
        } != nil)
        #expect(refused { try Editing.recomposeSpread(database: p, spreadId: 99) } != nil)
        #expect(refused { try Editing.setPhoto(database: p, spreadId: 5, cellIndex: 7, imageId: 1) } == "Ячейка 7 не найдена")
    }

    @Test func editingSetPhotoUsedElsewhereSwaps() throws {
        let layout = try Editing.setPhoto(database: path, spreadId: 5, cellIndex: 0, imageId: 2)
        #expect(edImages(layout) == [2, 1, 3])
        let placement = try #require(edCells(layout)[0]["placement"])
        let expected = Crop.solve(photoAspect: 0.7, regions: [], cell: try edCell("page_2h", 0))
        #expect(edNear(edNum(placement["crop"]?["x"]), expected.rect.x))
        #expect(edNear(edNum(placement["fit"]), expected.fit))
        let moved = try #require(edCells(layout)[1]["placement"])
        #expect(edNear(edNum(moved["fit"]),
                       Crop.solve(photoAspect: 1.5, regions: [], cell: try edCell("page_2h", 1)).fit))
    }

    @Test func editingSetPhotoFreeImageRecordsReplaced() throws {
        let layout = try Editing.setPhoto(database: path, spreadId: 5, cellIndex: 0, imageId: 4)
        let placement = try #require(edCells(layout)[0]["placement"])
        #expect(edImages(layout) == [4, 2, 3])
        #expect(placement["replaced_image_id"] == .int(1))
    }

    @Test func editingSetPhotoUnknownImageRaises() {
        let p = path
        #expect(refused { try Editing.setPhoto(database: p, spreadId: 5, cellIndex: 0, imageId: 404) }
                == "Кадр 404 недоступен для раскладки")
    }

    @Test func editingSetTemplateOtherCountRejected() throws {
        let p = path
        #expect(refused { try Editing.setTemplate(database: p, spreadId: 5, templateId: "grid_2x2") }
                == "Шаблон grid_2x2 рассчитан на 4 фото, в развороте 3")
        #expect(refused { try Editing.setTemplate(database: p, spreadId: 5, templateId: "nope") }
                == "Неизвестный шаблон: nope")
        #expect(edImages(try Editing.setTemplate(database: p, spreadId: 5, templateId: "page_2h")).sorted() == [1, 2, 3])
    }

    @Test func editingSetTemplateSameCountChangesTemplate() throws {
        let layout = try Editing.setTemplate(database: path, spreadId: 5, templateId: "page_2h_m")
        #expect(layout["spreads"]?[0]?["template_id"] == .string("page_2h_m"))
        #expect(edImages(layout).sorted() == [1, 2, 3])
        for c in edCells(layout) {
            let id = try #require(c["placement"]?["image_id"]?.intValue)
            let photo = editPool[id - 1]
            let expected = Crop.solve(
                photoAspect: photo.aspect, regions: photo.regions,
                cell: try edCell("page_2h_m", try #require(c["index"]?.intValue)))
            #expect(edNear(edNum(c["placement"]?["fit"]), expected.fit))
        }
    }

    @Test func editingCropWrongAspectRejected() throws {
        var crop = try edAspectCrop(0.7, 1)
        crop["w"]! *= 1.05
        let p = path
        let bad = edJSON(crop)
        #expect(refused { try Editing.setCrop(database: p, spreadId: 5, cellIndex: 1, crop: bad) } != nil)
        crop["w"]! /= 1.05 * 1.005
        let layout = try Editing.setCrop(database: p, spreadId: 5, cellIndex: 1, crop: edJSON(crop))
        #expect(!edCells(layout).isEmpty)
    }

    @Test func editingCropOutOfRangeRejected() throws {
        let p = path
        let outside = "Кроп выходит за пределы кадра"
        #expect(refused {
            try Editing.setCrop(database: p, spreadId: 5, cellIndex: 0, crop: edJSON(["x": 2, "y": 0, "w": 1, "h": 1]))
        } == outside)
        let crop = try edAspectCrop(0.7, 1, 0.5)
        for bad in [crop.merging(["x": 0.9]) { $1 }, crop.merging(["y": -0.1]) { $1 }, crop.merging(["w": 0, "h": 0]) { $1 }] {
            #expect(refused { try Editing.setCrop(database: p, spreadId: 5, cellIndex: 1, crop: edJSON(bad)) } == outside)
        }
        let finite = "Кроп должен содержать конечные числа"
        for bad: Double in [.nan, .infinity] {
            #expect(refused {
                try Editing.setCrop(database: p, spreadId: 5, cellIndex: 1, crop: edJSON(crop.merging(["x": bad]) { $1 }))
            } == finite)
        }
        let numbers = "Кроп должен содержать числа x, y, w, h"
        for bad in [JSONValue.string("a"), .null] {
            var object = edJSON(crop).objectValue!
            object["x"] = bad
            #expect(refused {
                try Editing.setCrop(database: p, spreadId: 5, cellIndex: 1, crop: .object(object))
            } == numbers)
        }
        #expect(refused { try Editing.setCrop(database: p, spreadId: 5, cellIndex: 1, crop: ["x": .int(0)]) } == numbers)
    }

    // Python float("0x10") raises; Swift Double("0x10") would be 16.
    @Test func editingCropHexStringRejected() throws {
        let crop = try edAspectCrop(0.7, 1)
        var object = edJSON(crop).objectValue!
        object["x"] = .string("0x0")
        #expect(refused {
            try Editing.setCrop(database: path, spreadId: 5, cellIndex: 1, crop: .object(object))
        } == "Кроп должен содержать числа x, y, w, h")
    }

    @Test func editingCropEdgeFloatNoiseAccepted() throws {
        var crop = try edAspectCrop(0.7, 1)
        crop["x"] = 1.0 - crop["w"]! + 1e-12
        let layout = try Editing.setCrop(database: path, spreadId: 5, cellIndex: 1, crop: edJSON(crop))
        #expect(edNear(edNum(edCells(layout)[1]["placement"]?["crop"]?["x"]), crop["x"]!))
    }

    @Test func editingSetCropCuttingFaceWarnsNotRejects() throws {
        var crop = try edAspectCrop(1.0, 2, 0.5)
        crop["x"] = 0.5
        let layout = try Editing.setCrop(database: path, spreadId: 5, cellIndex: 2, crop: edJSON(crop))
        let placement = try #require(edCells(layout)[2]["placement"])
        #expect(placement["warnings"]?.arrayValue?.contains(.string("face_cut")) == true)
        #expect(placement["crop"]?["x"]?.doubleValue == 0.5)
    }

    @Test func editingAlternativesSortedByFitAndCapped24() throws {
        let many = (0..<30).map { edPhoto(100 + $0, 0.5 + Double($0) * 0.05, "image:\(100 + $0)") }
        if !editReal {
            usePool(editPool + many)
        } else {
            for photo in many { try edSeedPhoto(db, root, photo) }
        }
        let result = try Editing.alternatives(database: path, spreadId: 5, cellIndex: 0)
        #expect(result.count == 24)
        let fits = result.map { edNum($0["fit"]) }
        #expect(fits == fits.sorted(by: >))
        #expect(Set(try #require(result[0].objectValue).keys) == [
            "image_id", "fit", "warnings", "in_selection", "placed", "similar"])
        if let hundred = result.first(where: { $0["image_id"] == .int(100) }) {
            #expect(hundred["in_selection"] == .bool(true))
        }
    }

    @Test func editingAlternativesTiesBreakByImageId() throws {
        usePool([9, 7, 8].map { edPhoto($0, 1.0, "image:\($0)") })
        let result = try Editing.alternatives(database: path, spreadId: 5, cellIndex: 0)
        #expect(result.compactMap { $0["image_id"]?.intValue } == [7, 8, 9])
    }

    @Test func editingAlternativesLimitedToSpreadStories() throws {
        usePool([edPhoto(10, 1.0, "image:10", storyId: 1), edPhoto(11, 1.0, "image:11", storyId: 2),
                 edPhoto(12, 1.0, "image:12", storyId: nil)])
        let result = try Editing.alternatives(database: path, spreadId: 5, cellIndex: 0)
        #expect(result.compactMap { $0["image_id"]?.intValue } == [10])
    }

    @Test func editingAlternativesSelectedRankedBeforeEqualSibling() throws {
        usePool([edPhoto(10, 1.0, "image:10", selected: false, storyId: 1),
                 edPhoto(11, 1.0, "image:11", selected: true, storyId: 1)])
        let result = try Editing.alternatives(database: path, spreadId: 5, cellIndex: 0)
        #expect(result.compactMap { $0["image_id"]?.intValue } == [11, 10])
        #expect(result[0]["fit"] == result[1]["fit"])
    }

    @Test func editingSwapRecomputesBothCrops() throws {
        let layout = try Editing.swapCells(database: path, spreadId: 5, cellA: 0, cellB: 1)
        #expect(edImages(layout) == [2, 1, 3])
        let cells = edCells(layout)
        #expect(edNear(edNum(cells[0]["placement"]?["fit"]),
                       Crop.solve(photoAspect: 0.7, regions: [], cell: try edCell("page_2h", 0)).fit))
        #expect(edNear(edNum(cells[1]["placement"]?["fit"]),
                       Crop.solve(photoAspect: 1.5, regions: [], cell: try edCell("page_2h", 1)).fit))
        #expect(edImages(try Editing.swapCells(database: path, spreadId: 5, cellA: 0, cellB: 0)) == [2, 1, 3])
        let p = path
        #expect(refused { try Editing.swapCells(database: p, spreadId: 5, cellA: 0, cellB: 9) } == "Ячейка 9 не найдена")
    }

    @Test func editingRecomposeKeepsSamePhotos() throws {
        _ = try Editing.swapCells(database: path, spreadId: 5, cellA: 0, cellB: 2)
        let layout = try Editing.recomposeSpread(database: path, spreadId: 5)
        #expect(edImages(layout).sorted() == [1, 2, 3])
        if !editReal {
            #expect(layout["spreads"]?[0]?["template_id"] == .string("page_2h"))
            #expect(layout["spreads"]?[0]?["warnings"] == ["draft"])
        }
    }

    @Test func editingEditsKeepDetectorScan() throws {
        _ = try Editing.alternatives(database: path, spreadId: 5, cellIndex: 0)
        _ = try Editing.setPhoto(database: path, spreadId: 5, cellIndex: 0, imageId: 5)
        _ = try Editing.recomposeSpread(database: path, spreadId: 5)
        if log.calls > 0 { #expect(log.allNil) }
    }

    @Test func editingAlternativesMarkPlacedAndSimilar() throws {
        let result = try Editing.alternatives(database: path, spreadId: 5, cellIndex: 0)
        var byId: [Int: JSONValue] = [:]
        for a in result { byId[a["image_id"]!.intValue!] = a }
        #expect(byId[2]?["placed"] == ["spread_id": 5, "position": 1, "cell_index": 1])
        #expect(byId[5]?["placed"] == .null)
        #expect(byId[4]?["similar"] == .bool(true) && byId[5]?["similar"] == .bool(false))
    }

    @Test func editingSimilarListsPlacedPhotoAndSiblings() throws {
        let result = try Editing.similar(database: path, spreadId: 5, cellIndex: 0)
        #expect(result.compactMap { $0["image_id"]?.intValue } == [1, 4])
        #expect(result[0]["placed"]?["cell_index"] == .int(0))
        #expect(result[1]["in_selection"] == .bool(false))
    }

    @Test func editingVariantsOtherTemplatesAndCounts() throws {
        usePool(editStoryPool)
        var found = try Editing.variants(database: path, spreadId: 5)
        let sets = found.map { $0["image_ids"]!.arrayValue!.compactMap(\.intValue) }
        if editReal {
            var collapsed: [[Int]] = []
            for (i, s) in sets.enumerated() where i == 0 || sets[i - 1] != s { collapsed.append(s) }
            #expect(collapsed == [[1, 2, 3], [1, 2, 3, 5], [1, 2]])
            #expect(found.filter { $0["image_ids"] == [1, 2, 3] }.allSatisfy { $0["template_id"] != .string("page_2h") })
            found = found.filter { $0["image_ids"] == [1, 2, 3, 5] }
        } else {
            #expect(sets == [[1, 2, 3, 5], [1, 2]])
            #expect(found[0]["template_id"] == .string("grid_2x2"))
        }
        let cell0 = try #require(found[0]["cells"]?[0])
        #expect(Set(try #require(cell0.objectValue).keys) == ["index", "x", "y", "w", "h", "image_id", "crop"])
        let x = edNum(cell0["x"]), w = edNum(cell0["w"])
        #expect(0 <= x && x <= 1 && 0 < w && w <= 1)
    }

    @Test func editingApplyVariantChangesCountAndTracksUnplaced() throws {
        usePool(editStoryPool)
        var layout = try Editing.applyVariant(database: path, spreadId: 5, templateId: "grid_2x2", imageIds: [1, 2, 3, 5])
        #expect(edImages(layout).sorted() == [1, 2, 3, 5])
        layout = try Editing.applyVariant(database: path, spreadId: 5, templateId: "pages", imageIds: [1, 2])
        #expect(edImages(layout).sorted() == [1, 2])
        #expect(try unplaced() == [["image_id": 3, "reason": "removed"], ["image_id": 5, "reason": "removed"]])
        _ = try Editing.applyVariant(database: path, spreadId: 5, templateId: "page_2h", imageIds: [1, 2, 3])
        #expect(try unplaced() == [["image_id": 5, "reason": "removed"]])
        let p = path
        #expect(refused {
            try Editing.applyVariant(database: p, spreadId: 5, templateId: "grid_2x2", imageIds: [1, 2])
        } == "Шаблон grid_2x2 не подходит для 2 фото")
        #expect(refused {
            try Editing.applyVariant(database: p, spreadId: 5, templateId: "full", imageIds: [404])
        } == "Кадр 404 недоступен для раскладки")
    }

    @Test func editingApplyVariantRejectsPhotoOnOtherSpread() throws {
        usePool(editStoryPool)
        try db.execute("INSERT INTO layout_spreads VALUES (6, 1, 2, 'full', '[1]', '[]', NULL)", [])
        try db.execute("INSERT INTO layout_placements VALUES (6, 0, 5, 0, 0, 1, 1, 0.5, '[]', NULL)", [])
        let p = path
        #expect(refused {
            try Editing.applyVariant(database: p, spreadId: 5, templateId: "grid_2x2", imageIds: [1, 2, 3, 5])
        } == "Кадр уже стоит на другом развороте")
    }

    @Test func editingRecomposeWithWishRepicksPhotos() throws {
        usePool(Array(editStoryPool[..<4]) + [edPhoto(5, 1.2, "image:5", regions: [editFace], storyId: 1)])
        var layout = try Editing.recomposeSpread(database: path, spreadId: 5, prompt: "больше лиц")
        #expect(edImages(layout).sorted() == [1, 3, 5])
        #expect(try unplaced() == [["image_id": 2, "reason": "removed"]])
        layout = try Editing.recomposeSpread(database: path, spreadId: 5, prompt: "пейзажи, без людей")
        #expect(edImages(layout).sorted() == [1, 2, 3])
        let p = path
        #expect(refused { try Editing.recomposeSpread(database: p, spreadId: 5, prompt: "что-нибудь красивое") }
                == "Пожелание не распознано: укажите лица, крупные планы или пейзажи")
    }

    @Test func editingMutationsOnOrderedAlbumRaiseReadsAllowed() throws {
        try db.execute("UPDATE albums SET status = 'ordered'", [])
        let p = path
        let message = "Альбом заказан: изменения недоступны"
        #expect(refused { try Editing.setPhoto(database: p, spreadId: 5, cellIndex: 0, imageId: 5) } == message)
        #expect(refused { try Editing.swapCells(database: p, spreadId: 5, cellA: 0, cellB: 1) } == message)
        #expect(refused { try Editing.setTemplate(database: p, spreadId: 5, templateId: "pages") } == message)
        #expect(refused {
            try Editing.setCrop(database: p, spreadId: 5, cellIndex: 0, crop: edJSON(["x": 0, "y": 0, "w": 1, "h": 1]))
        } == message)
        #expect(refused { try Editing.recomposeSpread(database: p, spreadId: 5) } == message)
        #expect(refused {
            try Editing.applyVariant(database: p, spreadId: 5, templateId: "page_2h", imageIds: [1, 2, 3])
        } == message)
        _ = try Editing.alternatives(database: p, spreadId: 5, cellIndex: 0)
        _ = try Editing.similar(database: p, spreadId: 5, cellIndex: 0)
        _ = try Editing.variants(database: p, spreadId: 5)
    }

    @Test func editingParsePromptWeightsAndLabels() {
        let parsed = Editing.parsePrompt("больше лиц")
        #expect(parsed["weights"] == ["faces": 1.0])
        #expect(parsed["labels"] == ["больше лиц"])
    }

    @Test func editingFixtureSeedsRealPoolLikeFake() throws {
        // SUPERLITE_REAL runs use the real loadPool, so the fixture must hold the same pool.
        let real = Dictionary(uniqueKeysWithValues: try Facts.loadPool(db, albumId: 1, detector: nil).map { ($0.imageId, $0) })
        #expect(real.keys.sorted() == editPool.map(\.imageId))
        #expect(real[1]?.unitKey == real[4]?.unitKey && real[1]?.unitKey != real[5]?.unitKey)
        for photo in editPool {
            let got = try #require(real[photo.imageId])
            #expect(edNear(got.aspect, photo.aspect))
            #expect(got.selected == photo.selected)
            #expect(got.regions.count == photo.regions.count)
            for (a, b) in zip(got.regions, photo.regions) {
                #expect(a.kind == b.kind)
                #expect(edNear(a.bbox.x, b.bbox.x) && edNear(a.bbox.y, b.bbox.y)
                        && edNear(a.bbox.w, b.bbox.w) && edNear(a.bbox.h, b.bbox.h))
            }
        }
    }
}
