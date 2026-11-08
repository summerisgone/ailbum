import Foundation
import Testing
@testable import AilbumCore

private func bridgeTempDB() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/a.db"
}

private func bridgePopulate() throws -> String {
    let path = try bridgeTempDB()
    let db = try Database.open(path: path)
    try db.execute("INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','none','{}','{}','completed')", [])
    for i in 1...3 {
        try db.execute(
            """
            INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
            file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)
            VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024', ?, '{}', '{}', 't')
            """,
            [.integer(i), .text("/p/\(i).jpg"), .text("\(i).jpg"), .text("\(i).jpg"), .text("sha\(i)")])
        try db.execute(
            """
            INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,
            quality, is_blurry, story_id, selected) VALUES ('r1', ?, ?, 0.5, 0.5, 0.5, 0, 1, 0)
            """, [.integer(i), .text("p\(i)")])
    }
    _ = try Albums.create(db, title: "T", sources: ["/p"], runId: "r1", targetCount: 2)
    return path
}

private func call(_ db: String, _ action: String, _ payload: JSONValue = [:]) throws -> JSONValue {
    try DesktopBridge.dispatch(database: db, action: action, payload: payload)
}

private let layoutParamsPayload: [String: JSONValue] = [
    "album_id": 1, "orientation": "vertical", "spread_count": 4, "min_photos": 3, "max_photos": 5,
    "assistant": "off",
]

// Real code by default; the recording fake only when SUPERLITE_REAL is not 1.
private func installLayoutFakes() -> Bool {
    if ProcessInfo.processInfo.environment["SUPERLITE_REAL"] == "1" { return false }
    DesktopBridge.layoutHook = { name, args in
        calls.append((name, args))
        switch name {
        case "preflight": return ["errors": []]
        case "alternatives": return [["image_id": 2]]
        default: return ["id": 1]
        }
    }
    return true
}

nonisolated(unsafe) private var calls: [(String, [Any])] = []

@Suite(.serialized) struct DesktopBridgeSuite {
    @Test func libraryBootstrapHasMediaPath() throws {
        let db = try bridgePopulate()
        let data = try call(db, "library.bootstrap", ["album_id": 1])
        #expect(data["album"]?["id"] == 1 && data["selected_count"] == 2)
        let photos = data["photos"]?.arrayValue ?? []
        #expect(!photos.isEmpty && photos.allSatisfy { $0.objectValue?["media_path"] != nil })
        #expect(try call(db, "library.bootstrap")["album"]?["id"] == 1)
    }

    @Test func mediaPathUsesImageSource() throws {
        let db = try bridgePopulate()
        let proxy = Proxies.photoProxy(database: db, sha256: "sha1")
        try FileManager.default.createDirectory(
            atPath: (proxy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: proxy))
        let photos = try call(db, "library.bootstrap", ["album_id": 1])["photos"]?.arrayValue ?? []
        let first = photos.first { $0["id"] == 1 }
        #expect(first?["media_path"]?.stringValue == proxy)
    }

    @Test func bridgeSelectionActions() throws {
        let db = try bridgePopulate()
        #expect(try call(db, "favorite.set", ["album_id": 1, "image_id": 3, "favorite": true])["favorite"] == true)
        #expect(try call(db, "target.set", ["album_id": 1, "target_count": 3])["target_count"] == 3)
        #expect(try call(db, "selection.autofill", ["album_id": 1])["selected_count"] == 3)
        #expect(try call(db, "album.list").arrayValue?.count == 1)
    }

    @Test func albumLifecycleActions() throws {
        let db = try bridgePopulate()
        #expect(try call(db, "album.rename", ["album_id": 1, "title": "Новый"])["title"] == "Новый")
        #expect(try call(db, "album.status", ["album_id": 1, "status": "ordered"])["status"] == "ordered")
        #expect(try call(db, "album.prepare_archive", ["album_id": 1])["album_id"] == 1)
        #expect(try call(db, "album.complete_archive", ["album_id": 1, "trashed": []])["archived"] == 0)
        #expect(try call(db, "album.confirm_missing", ["image_ids": [1]]) == ["confirmed": 0])
    }

    @Test func bridgeAlbumDelete() throws {
        let db = try bridgePopulate()
        #expect(try call(db, "album.delete", ["album_id": 1, "forget_decisions": false]) == ["deleted": true])
        #expect(try call(db, "album.list") == [])
    }

    @Test func bridgeUsage() throws {
        let db = try bridgePopulate()
        #expect(try call(db, "album.usage")["images"] != nil)
    }

    @Test func bridgeFaceThumbnail() throws {
        let db = try bridgePopulate()
        DesktopBridge.faceThumbnailOverride = { _, f in Data("jpg".utf8) + Data([UInt8(f)]) }
        defer { DesktopBridge.faceThumbnailOverride = nil }
        let out = try call(db, "face.thumbnail", ["face_id": 5])
        #expect(out["mime_type"] == "image/jpeg")
        #expect(Data(base64Encoded: out["base64"]?.stringValue ?? "") == Data("jpg".utf8) + Data([5]))
    }

    @Test func unknownAndErrorResponse() throws {
        let db = try bridgePopulate()
        do {
            _ = try call(db, "nope")
            Issue.record("expected throw")
        } catch AilbumError.invalid(let m) {
            #expect(m == "Unknown desktop action: nope")
        }
        let line = #"{"id":1,"action":"favorite.set","payload":{"album_id":99,"image_id":1,"favorite":true}}"#
        let out = try JSONValue.parse(DesktopBridge.respond(database: db, line: line))
        #expect(out["id"] == 1 && out["error"] != nil)
    }

    @Test func respondProtocol() throws {
        let db = try bridgePopulate()
        #expect(DesktopBridge.respond(database: db, line: #"{"id":7,"action":"nope"}"#)
                == #"{"error":"Unknown desktop action: nope","id":7}"#)
        #expect(DesktopBridge.respond(database: db, line: #"{"id":"a","action":"ping","payload":null}"#)
                == #"{"id":"a","result":{"ok":true}}"#)
        #expect(DesktopBridge.respond(database: db, line: "[1]")
                == #"{"error":"Desktop request must be a JSON object","id":null}"#)
        #expect(DesktopBridge.respond(database: db, line: "{bad")
                .hasSuffix(#","id":null}"#))
        #expect(DesktopBridge.respond(database: db, line: #"{"action":"ping"}"#) == #"{"error":"'id'","id":null}"#)
        // Unescaped UTF-8, sorted keys, no spaces.
        let renamed = DesktopBridge.respond(
            database: db, line: #"{"id":2,"action":"album.rename","payload":{"album_id":1,"title":"Новый/т"}}"#)
        #expect(renamed.contains(#""title":"Новый/т""#) && !renamed.contains(" "))
        #expect(renamed.hasPrefix(#"{"id":2,"result":{"#))
    }

    @Test func bridgeRoutesAllLayoutActions() throws {
        guard installLayoutFakes() else { return }
        defer { DesktopBridge.layoutHook = nil; calls = [] }
        calls = []
        let db = try bridgeTempDB()
        func d(_ action: String, _ p: JSONValue) throws -> JSONValue { try call(db, action, p) }
        #expect(try d("layout.preflight", .object(layoutParamsPayload)) == ["errors": []])
        #expect(try d("layout.alternatives", ["spread_id": "5", "cell_index": 1]) == [["image_id": 2]])
        _ = try d("layout.set_photo", ["spread_id": 5, "cell_index": 0, "image_id": 7])
        _ = try d("layout.swap_cells", ["spread_id": 5, "cell_a": 0, "cell_b": 1])
        _ = try d("layout.set_template", ["spread_id": 5, "template_id": "page_2h"])
        let crop: JSONValue = ["x": 0.1, "y": 0, "w": 0.5, "h": 1]
        _ = try d("layout.set_crop", ["spread_id": 5, "cell_index": 0, "crop": crop])
        _ = try d("layout.recompose_spread", ["spread_id": 5, "prompt": "лица"])
        _ = try d("layout.similar", ["spread_id": 5, "cell_index": 2])
        _ = try d("layout.variants", ["spread_id": 5])
        _ = try d("layout.apply_variant", ["spread_id": 5, "template_id": "pages", "image_ids": ["1", 2]])
        #expect(calls.map(\.0) == [
            "preflight", "alternatives", "set_photo", "swap_cells",
            "set_template", "set_crop", "recompose_spread", "similar", "variants", "apply_variant",
        ])
        #expect(calls[6].1.count == 3 && calls[6].1[1] as? Int == 5 && calls[6].1[2] as? String == "лица")
        #expect(calls[9].1[2] as? String == "pages" && calls[9].1[3] as? [Int] == [1, 2])
        #expect(try d("layout.parse_prompt", ["prompt": "больше лиц"])["labels"] == ["больше лиц"])
        #expect(calls[2].1[1] as? Int == 5 && calls[2].1[2] as? Int == 0 && calls[2].1[3] as? Int == 7)
        #expect(calls[5].1[3] as? JSONValue == crop)
    }

    @Test func dispatchPreflightBuildsParams() throws {
        guard installLayoutFakes() else { return }
        defer { DesktopBridge.layoutHook = nil; calls = [] }
        calls = []
        let db = try bridgeTempDB()
        _ = try call(db, "layout.preflight", .object(layoutParamsPayload))
        #expect(calls[0].1[1] as? Int == 1)
        #expect(calls[0].1[2] as? LayoutParams
                == LayoutParams(orientation: "vertical", spreadCount: 4, minPhotos: 3, maxPhotos: 5, assistant: "off"))
        var long = layoutParamsPayload
        long["prompt"] = .string(String(repeating: "лица", count: 400))
        _ = try call(db, "layout.preflight", .object(long))
        let expected = String(String.UnicodeScalarView(String(repeating: "лица", count: 400).unicodeScalars.prefix(500)))
        #expect((calls[1].1[2] as? LayoutParams)?.prompt == expected)
        #expect(expected.unicodeScalars.count == 500)
    }

    @Test func dispatchLayoutGetNull() throws {
        let db = try bridgeTempDB()
        _ = try call(db, "database.initialize")
        #expect(try call(db, "layout.get", ["album_id": 999]) == .null)
    }

    @Test func dispatchTemplates() throws {
        let result = try call("x.db", "layout.templates", ["orientation": "vertical", "photo_count": 3])
        let items = result.arrayValue ?? []
        #expect(Set(items.compactMap { $0["id"]?.stringValue }) == ["page_2h", "page_2h_m", "row_3", "pano_2"])
        let cell = items[0]["cells"]?[0]?.objectValue ?? [:]
        #expect(Set(cell.keys) == ["index", "x", "y", "w", "h"])
        let x = cell["x"]?.doubleValue ?? -1, w = cell["w"]?.doubleValue ?? -1
        #expect(x >= 0 && x <= 1 && w > 0 && w <= 1)
        #expect(items[0]["photo_count"] == 3)
    }
}
