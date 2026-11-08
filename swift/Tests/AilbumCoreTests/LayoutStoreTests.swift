import Foundation
import Testing
@testable import AilbumCore

private func makeStoreDB() throws -> Database {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-ls-\(UUID().uuidString)"
    let db = try Database.open(path: dir + "/db.sqlite3")
    try db.execute("INSERT INTO analysis_runs VALUES ('r', 's', 'o', 't', 't', 'f', '{}', '{}', 'completed')", [])
    try db.execute(
        "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
        + " VALUES (1, 'u1', 'Альбом', 'r', 't', 't')", [])
    for id in 1...10 {
        try db.execute(
            """
            INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
                file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)
            VALUES (?, ?, 'root', ?, ?, 'jpg', 1, 't', 'x', '{}', '{}', 't')
            """,
            [.integer(id), .text("/p/\(id).jpg"), .text("\(id).jpg"), .text("\(id).jpg")])
        try db.execute("INSERT INTO album_photos VALUES (1, ?, ?, 't')", [.integer(id), .integer(id)])
    }
    for (id, title) in [(1, "Ужин"), (2, "Прогулка")] {
        try db.execute("INSERT INTO stories (run_id, story_id, title) VALUES ('r', ?, ?)", [.integer(id), .text(title)])
    }
    return db
}

private let storeParams = LayoutParams(
    orientation: "vertical", spreadCount: 2, minPhotos: 3, maxPhotos: 6, assistant: "auto", prompt: "акцент на лицах")

private func storeSpread(_ storyIds: [Int] = [1], first: Int = 7) -> SpreadDraft {
    SpreadDraft(
        templateId: "page_2h", storyIds: storyIds,
        placements: [
            PlacementDraft(cellIndex: 0, imageId: first, crop: Rect(x: 0.1, y: 0.0, w: 0.6, h: 1.0), fit: 0.82,
                           warnings: [], replacedImageId: nil),
            PlacementDraft(cellIndex: 1, imageId: first + 1, crop: Rect(x: 0, y: 0, w: 1, h: 1), fit: 0.5,
                           warnings: ["face_cut"], replacedImageId: 3),
            PlacementDraft(cellIndex: 2, imageId: first + 2, crop: Rect(x: 0, y: 0, w: 1, h: 1), fit: 0.9,
                           warnings: [], replacedImageId: nil),
        ],
        score: 0, warnings: ["underfilled"], alternatives: [], assistantReason: "лучше читается")
}

@discardableResult
private func saveStore(_ db: Database, _ spreads: [SpreadDraft]? = nil) throws -> Int {
    try LayoutStore.saveLayout(
        db, albumId: 1, runId: "r", params: storeParams, spreads: spreads ?? [storeSpread()],
        unplaced: [["image_id": 9, "reason": "capacity"]], warnings: ["w"],
        selectionHash: try LayoutStore.selectionHash(db, albumId: 1), assistantModel: "model-x")
}

private func storeCount(_ db: Database, _ table: String) throws -> Int {
    guard case .integer(let n)? = try db.query("SELECT COUNT(*) AS n FROM \(table)", []).first?["n"] else { return -1 }
    return Int(n)
}

private func cellsOf(_ db: Database) throws -> [JSONValue] {
    try #require(try LayoutStore.loadLayout(db, albumId: 1))["spreads"]![0]!["cells"]!.arrayValue!
}

@Suite struct LayoutStoreTests {
    @Test func storeLoadMissingIsNone() throws {
        let db = try makeStoreDB()
        #expect(try LayoutStore.loadLayout(db, albumId: 999) == nil)
        #expect(try LayoutStore.loadLayout(db, albumId: 1) == nil)
    }

    @Test func storeRoundTripMatchesContract() throws {
        let db = try makeStoreDB()
        let layoutId = try saveStore(db)
        let layout = try #require(try LayoutStore.loadLayout(db, albumId: 1))
        let keys: Set = ["id", "album_id", "run_id", "prompt", "orientation", "spread_count", "min_photos",
                         "max_photos", "stale", "assistant_model", "warnings", "unplaced", "format", "spreads"]
        #expect(keys.isSubset(of: Set(layout.objectValue!.keys)))
        #expect(layout["id"] == .int(layoutId))
        #expect(layout["run_id"] == "r")
        #expect(layout["album_id"] == 1)
        #expect(layout["prompt"] == "акцент на лицах")
        #expect(layout["stale"] == .bool(false))
        #expect(layout["assistant_model"] == "model-x")
        #expect(layout["warnings"] == ["w"])
        #expect(layout["unplaced"] == [["image_id": 9, "reason": "capacity"]])
        #expect(layout["format"] == [
            "spread_w_mm": .double(426.0), "spread_h_mm": .double(303.0), "bleed_mm": .double(3.0),
            "safe_mm": .double(3.0),
        ])
        let spread = try #require(layout["spreads"]?[0])
        let spreadKeys: Set = ["id", "position", "template_id", "story_ids", "story_title", "warnings",
                               "assistant_reason", "cells"]
        #expect(spreadKeys.isSubset(of: Set(spread.objectValue!.keys)))
        #expect(spread["position"] == 1)
        #expect(spread["story_ids"] == [1])
        #expect(spread["warnings"] == ["underfilled"])
        #expect(spread["assistant_reason"] == "лучше читается")
        let cell = try #require(spread["cells"]?[0])
        let cellKeys: Set = ["index", "x", "y", "w", "h", "crosses_spine", "placement"]
        #expect(cellKeys.isSubset(of: Set(cell.objectValue!.keys)))
        #expect(cell["placement"] == [
            "image_id": 7,
            "crop": ["x": .double(0.1), "y": .double(0.0), "w": .double(0.6), "h": .double(1.0)],
            "fit": .double(0.82),
            "warnings": [],
            "replaced_image_id": nil,
        ])
        #expect(spread["cells"]?[1]?["placement"]?["warnings"] == ["face_cut"])
        #expect(spread["cells"]?[1]?["placement"]?["replaced_image_id"] == 3)
        #expect(layout["spreads"]?[0]?["cells"]?[0]?["placement"]?["image_id"] == 7)
    }

    @Test func storeCellFractionsFromTemplate() throws {
        let db = try makeStoreDB()
        try saveStore(db)
        let cells = try cellsOf(db)
        func d(_ i: Int, _ k: String) -> Double { cells[i][k]!.doubleValue! }
        #expect(d(0, "x") == 0.0 && d(0, "y") == 0.0 && d(0, "h") == 1.0)
        #expect(abs(d(0, "w") - 210.5 / 426.0) <= 1e-4)
        #expect(abs(d(1, "x") - 215.5 / 426.0) <= 1e-4)
        #expect(abs(d(1, "h") - 149.0 / 303.0) <= 1e-4)
        #expect(abs(d(2, "y") - 154.0 / 303.0) <= 1e-4)
        #expect(cells.map { $0["crosses_spine"]!.boolValue! } == [false, false, false])
        for i in 0..<3 {
            #expect(0.0 <= d(i, "x") && d(i, "x") + d(i, "w") <= 1.0)
            #expect(0.0 <= d(i, "y") && d(i, "y") + d(i, "h") <= 1.0)
        }
    }

    @Test func storeFullTemplateCrossesSpine() throws {
        let db = try makeStoreDB()
        var spread = storeSpread()
        spread.templateId = "full"
        spread.placements = Array(spread.placements.prefix(1))
        try saveStore(db, [spread])
        let cell = try cellsOf(db)[0]
        #expect(cell["crosses_spine"] == .bool(true))
        #expect(cell["x"] == .double(0.0) && cell["w"] == .double(1.0))
    }

    @Test func storyTitleJoinedForMerged() throws {
        let db = try makeStoreDB()
        try saveStore(db, [storeSpread([1, 2])])
        let spread = try #require(try LayoutStore.loadLayout(db, albumId: 1))["spreads"]![0]!
        #expect(spread["story_title"] == "Ужин + Прогулка")
        #expect(spread["story_ids"] == [1, 2])
    }

    @Test func unknownStoryGivesEmptyTitle() throws {
        let db = try makeStoreDB()
        try saveStore(db, [storeSpread([99])])
        #expect(try LayoutStore.loadLayout(db, albumId: 1)?["spreads"]?[0]?["story_title"] == "")
    }

    @Test func storeSaveReplacesPreviousLayout() throws {
        let db = try makeStoreDB()
        try saveStore(db, [storeSpread(), storeSpread([2], first: 1)])
        try saveStore(db, [storeSpread([2], first: 4)])
        let layout = try #require(try LayoutStore.loadLayout(db, albumId: 1))
        #expect(layout["spreads"]?.arrayValue?.count == 1)
        #expect(layout["spreads"]?[0]?["story_ids"] == [2])
        #expect(try storeCount(db, "layouts") == 1)
        #expect(try storeCount(db, "layout_spreads") == 1)
        #expect(try storeCount(db, "layout_placements") == 3)
    }

    @Test func storeDeleteAlbumCascades() throws {
        let db = try makeStoreDB()
        try saveStore(db)
        try db.execute("DELETE FROM albums WHERE id = 1", [])
        for table in ["layouts", "layout_spreads", "layout_placements"] {
            #expect(try storeCount(db, table) == 0)
        }
    }

    @Test func storeStaleAfterSelectionChange() throws {
        let db = try makeStoreDB()
        try saveStore(db)
        #expect(try LayoutStore.loadLayout(db, albumId: 1)?["stale"] == .bool(false))
        try db.execute("DELETE FROM album_photos WHERE album_id = 1 AND image_id = 10", [])
        #expect(try LayoutStore.loadLayout(db, albumId: 1)?["stale"] == .bool(true))
    }

    @Test func storeSelectionHashIsOrderIndependent() throws {
        let db = try makeStoreDB()
        let first = try LayoutStore.selectionHash(db, albumId: 1)
        try db.execute("UPDATE album_photos SET position = 100 - position", [])
        #expect(try LayoutStore.selectionHash(db, albumId: 1) == first)
        #expect(first.count == 64)
        #expect(try LayoutStore.selectionHash(db, albumId: 999) != first)
    }

    @Test func storeAlbumRunAndRequireDraft() throws {
        let db = try makeStoreDB()
        #expect(try LayoutStore.albumRun(db, albumId: 1) == "r")
        #expect(throws: AilbumError.invalid("Альбом не найден")) { try LayoutStore.albumRun(db, albumId: 999) }
        try db.execute("UPDATE albums SET run_id = NULL", [])
        #expect(throws: AilbumError.invalid("У альбома нет анализа")) { try LayoutStore.albumRun(db, albumId: 1) }
        try LayoutStore.requireDraft(db, albumId: 1)
        try db.execute("UPDATE albums SET status = 'ordered'", [])
        #expect(throws: AilbumError.invalid("Альбом заказан: изменения недоступны")) {
            try LayoutStore.requireDraft(db, albumId: 1)
        }
    }

    @Test func storeStaleFlagUnchangedForMigratedLayout() throws {
        let db = try makeStoreDB()
        try saveStore(db)
        try db.execute("UPDATE albums SET status = 'ordered'", [])
        #expect(try LayoutStore.loadLayout(db, albumId: 1)?["stale"] == .bool(false))
    }

    // Golden from Python load_layout (ids masked to 0) for a merged-story spread.
    @Test func storeLoadLayoutMatchesPythonGolden() throws {
        let db = try makeStoreDB()
        try saveStore(db, [storeSpread([1, 2])])
        var layout = try #require(try LayoutStore.loadLayout(db, albumId: 1))
        var object = layout.objectValue!
        object["id"] = .int(0)
        var spreads = object["spreads"]!.arrayValue!
        for i in spreads.indices {
            var s = spreads[i].objectValue!
            s["id"] = .int(0)
            spreads[i] = .object(s)
        }
        object["spreads"] = .array(spreads)
        layout = .object(object)
        let golden = #"""
        {"album_id": 1, "assistant_model": "model-x", "format": {"bleed_mm": 3.0, "safe_mm": 3.0, "spread_h_mm": 303.0, "spread_w_mm": 426.0}, "id": 0, "max_photos": 6, "min_photos": 3, "orientation": "vertical", "prompt": "акцент на лицах", "run_id": "r", "spread_count": 2, "spreads": [{"assistant_reason": "лучше читается", "cells": [{"crosses_spine": false, "h": 1.0, "index": 0, "placement": {"crop": {"h": 1.0, "w": 0.6, "x": 0.1, "y": 0.0}, "fit": 0.82, "image_id": 7, "replaced_image_id": null, "warnings": []}, "w": 0.49413, "x": 0.0, "y": 0.0}, {"crosses_spine": false, "h": 0.49175, "index": 1, "placement": {"crop": {"h": 1.0, "w": 1.0, "x": 0.0, "y": 0.0}, "fit": 0.5, "image_id": 8, "replaced_image_id": 3, "warnings": ["face_cut"]}, "w": 0.49413, "x": 0.50587, "y": 0.0}, {"crosses_spine": false, "h": 0.49175, "index": 2, "placement": {"crop": {"h": 1.0, "w": 1.0, "x": 0.0, "y": 0.0}, "fit": 0.9, "image_id": 9, "replaced_image_id": null, "warnings": []}, "w": 0.49413, "x": 0.50587, "y": 0.50825}], "id": 0, "position": 1, "story_ids": [1, 2], "story_title": "Ужин + Прогулка", "template_id": "page_2h", "warnings": ["underfilled"]}], "stale": false, "unplaced": [{"image_id": 9, "reason": "capacity"}], "warnings": ["w"]}
        """#
        // String compare keeps 1.0 vs 1 distinct (JSONDecoder reads 1.0 as Int).
        #expect(LayoutStore.dumps(layout) == golden)
        let raw = try db.query("SELECT unplaced_json, warnings_json FROM layouts", [])[0]
        #expect(raw["unplaced_json"] == .text(#"[{"image_id": 9, "reason": "capacity"}]"#))
        #expect(raw["warnings_json"] == .text(#"["w"]"#))
        let spreadRaw = try db.query("SELECT story_ids_json, warnings_json FROM layout_spreads", [])[0]
        #expect(spreadRaw["story_ids_json"] == .text("[1, 2]"))
    }
}
