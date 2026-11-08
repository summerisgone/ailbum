import Foundation
import Testing
@testable import AilbumCore

private func libTempDB() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/a.db"
}

private func libPopulate(_ path: String, n: Int = 6, missing: Set<Int> = []) throws -> Int {
    let db = try Database.open(path: path)
    try db.execute("INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','none','{}','{}','completed')", [])
    for i in 1...n {
        let avail = missing.contains(i) ? "archived" : "present"
        try db.execute(
            """
            INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
            file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,
            indexed_at, availability)
            VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024-01-01', ?, '{}', '{}', 't', ?)
            """,
            [.integer(i), .text("/p/\(i).jpg"), .text("\(i).jpg"), .text("\(i).jpg"), .text("sha\(i)"), .text(avail)])
        try db.execute(
            """
            INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,
            quality, is_blurry, story_id, selected)
            VALUES ('r1', ?, ?, 0.5, 0.5, ?, 0, ?, 0)
            """,
            [.integer(i), .text("p\(i)"), .real(Double(i) / 10), .integer(i % 2)])
    }
    return try Albums.create(db, title: "T", sources: ["/p"], runId: "r1", targetCount: 3)
}

private func libExpectInvalid(_ body: () throws -> Void, contains: String? = nil) {
    do {
        try body()
        Issue.record("expected throw")
    } catch AilbumError.invalid(let msg) {
        if let c = contains { #expect(msg.contains(c)) }
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Suite struct AlbumLibraryTests {
    @Test func libSetPhotoEventOnlyOnChange() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let db = try Database.open(path: path)
        let r = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 2, selected: true, source: "manual")
        #expect(r == ["album_id": .int(aid), "image_id": 2, "favorite": true, "changed": true, "selected_count": 1])
        #expect(try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 2, selected: true, source: "manual")["changed"] == false)
        #expect(try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 3, selected: false, source: "manual")["changed"] == false)
        #expect(try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 2, selected: false, source: "manual")["changed"] == true)
        let ev = try db.query("SELECT action, source, run_id FROM selection_events ORDER BY id", [])
        #expect(ev.map { [$0["action"], $0["source"], $0["run_id"]] } ==
                [[.text("add"), .text("manual"), .text("r1")], [.text("remove"), .text("manual"), .text("r1")]])
    }

    @Test func libSetPhotoNonDraftAndForeignImage() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let db = try Database.open(path: path)
        libExpectInvalid { _ = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 99, selected: true, source: "manual") }
        _ = try Albums.setStatus(db, aid, "ordered")
        libExpectInvalid({ _ = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 1, selected: true, source: "manual") },
                         contains: "Альбом заказан")
        libExpectInvalid { _ = try AlbumLibrary.setTarget(db, albumId: aid, targetCount: 5) }
        libExpectInvalid { _ = try AlbumLibrary.autofill(db, albumId: aid) }
    }

    @Test func libSelectionHashMatchesPythonSha256() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let db = try Database.open(path: path)
        _ = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 3, selected: true, source: "manual")
        _ = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 1, selected: true, source: "manual")
        let golden = "ef96f1f6b55a072e70c2b4e8bd6585793f5f05ace0c01a5b07fad298a4d0051a"  // hashlib.sha256(b"1,3")
        #expect(try AlbumLibrary.selectionHash(db, albumId: aid) == golden)
    }

    @Test func libSetTargetBounds() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let db = try Database.open(path: path)
        for bad in [0, 1000] {
            libExpectInvalid { _ = try AlbumLibrary.setTarget(db, albumId: aid, targetCount: bad) }
        }
        #expect(try AlbumLibrary.setTarget(db, albumId: aid, targetCount: 5)["target_count"] == 5)
    }

    @Test func libFirstOpenSeedsTargetCountOnce() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let data = try AlbumLibrary.getLibrary(database: path, albumId: aid)
        #expect(data["selected_count"] == 3 && data["target_count"] == 3)
        let db = try Database.open(path: path)
        let ev = try db.query("SELECT action, source FROM selection_events", [])
        #expect(ev.count == 3 && ev.allSatisfy { $0["action"] == .text("seed") && $0["source"] == .text("auto") })
        _ = try AlbumLibrary.getLibrary(database: path, albumId: aid)
        #expect(try db.query("SELECT COUNT(*) AS c FROM selection_events", []).first?["c"] == .integer(3))
    }

    @Test func libAutofillKeepsManualAndTarget() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let db = try Database.open(path: path)
        _ = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: 1, selected: true, source: "manual")
        let res = try AlbumLibrary.autofill(db, albumId: aid)
        #expect(res["selected_count"] == 3 && res["added"]?.arrayValue?.count == 2)
        #expect(res["added"]?.arrayValue?.contains(1) == false)
        let ids = try db.query("SELECT image_id FROM album_photos ORDER BY position", []).map { $0["image_id"] }
        #expect(ids.count == 3 && ids[0] == .integer(1))
        let actions = try db.query("SELECT action, source FROM selection_events WHERE source = 'auto'", [])
        #expect(actions.count == 2 && actions.allSatisfy { $0["action"] == .text("add") })
    }

    @Test func libListsArchivedWithAvailability() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path, missing: [6])
        let db = try Database.open(path: path)
        for i in [6, 1, 2] { _ = try AlbumLibrary.setPhoto(db, albumId: aid, imageId: i, selected: true, source: "manual") }
        let data = try AlbumLibrary.getLibrary(database: path, albumId: aid)
        let photos = data["photos"]?.arrayValue ?? []
        func byId(_ i: Int) -> JSONValue? { photos.first { $0["id"] == .int(i) } }
        #expect(byId(6)?["availability"] == "archived" && byId(6)?["favorite"] == true)
        #expect(byId(1)?["availability"] == "present")
        #expect(data["album"]?["id"] == .int(aid) && data["albums"]?[0]?["id"] == .int(aid))
        #expect(data["run"]?["id"] == "r1" && data["run"]?["summary"]?.objectValue != nil)
    }

    @Test func libNoAlbum() throws {
        let path = try libTempDB()
        _ = try Database.open(path: path)
        let data = try AlbumLibrary.getLibrary(database: path, albumId: nil)
        #expect(data["album"] == .null && data["albums"] == [] && data["photos"] == [])
        #expect(data["target_count"] == 24)
    }

    @Test func libDefaultAlbumPrefersDraft() throws {
        let path = try libTempDB()
        let aid = try libPopulate(path)
        let db = try Database.open(path: path)
        let other = try Albums.create(db, title: "Z", sources: ["/q"], runId: nil, targetCount: 24)
        _ = try Albums.setStatus(db, other, "ordered")
        #expect(try AlbumLibrary.getLibrary(database: path, albumId: nil)["album"]?["id"] == .int(aid))
    }
}
