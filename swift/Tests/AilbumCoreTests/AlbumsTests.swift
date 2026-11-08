import Foundation
import Testing
@testable import AilbumCore

private func makeAlbumsDB() throws -> Database {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let db = try Database.open(path: dir + "/a.sqlite")
    for r in ["r1", "r2"] {
        try db.execute("INSERT INTO analysis_runs VALUES ('\(r)','/p','/o','t','t','x','{}','{}','completed')", [])
    }
    return db
}

private func expectInvalid(_ body: () throws -> Void, contains: String? = nil) {
    do {
        try body()
        Issue.record("expected throw")
    } catch AilbumError.invalid(let msg) {
        if let c = contains { #expect(msg.contains(c)) }
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Suite struct AlbumsTests {
    @Test func createGet() throws {
        let db = try makeAlbumsDB()
        let i = try Albums.create(db, title: "Турция", sources: ["/p", "/p"], runId: "r1", targetCount: 24)
        let a = try Albums.get(db, i)
        #expect(a["sources"] == ["/p"] && a["status"] == "draft" && a["photo_count"] == 0)
        #expect(a["target_count"] == 24 && a["run_id"] == "r1")
        expectInvalid({ _ = try Albums.get(db, 99) }, contains: "не найден")
    }

    @Test func sourcesSortedAndKeys() throws {
        let db = try makeAlbumsDB()
        let i = try Albums.create(db, title: "A", sources: ["/b", "/a", "/a"], runId: nil, targetCount: 24)
        #expect(i == 1)
        let a = try Albums.get(db, 1)
        #expect(a["sources"] == ["/a", "/b"])
        #expect(Set(a.objectValue!.keys) == ["id", "public_id", "title", "purpose", "status", "target_count",
            "run_id", "sources", "photo_count", "ordered_at", "archived_at", "updated_at"])
        #expect(a["run_id"] == .null)
    }

    @Test func transitions() throws {
        let db = try makeAlbumsDB()
        let i = try Albums.create(db, title: "t", sources: ["/p"], runId: nil, targetCount: 24)
        #expect(try Albums.setStatus(db, i, "draft")["status"] == "draft")
        let a = try Albums.setStatus(db, i, "ordered")
        #expect(a["ordered_at"] != .null)
        #expect(try Albums.setStatus(db, i, "draft")["ordered_at"] == .null)
        expectInvalid({ _ = try Albums.setStatus(db, i, "archived") }, contains: "Переход draft -> archived недоступен")
        _ = try Albums.setStatus(db, i, "ordered")
        #expect(try Albums.setStatus(db, i, "archived")["archived_at"] != .null)
        for target in ["draft", "ordered"] {
            expectInvalid({ _ = try Albums.setStatus(db, i, target) })
        }
    }

    @Test func deleteArchivedRequiresFlag() throws {
        let db = try makeAlbumsDB()
        let i = try Albums.create(db, title: "t", sources: ["/p"], runId: nil, targetCount: 24)
        _ = try Albums.setStatus(db, i, "ordered")
        expectInvalid({ try Albums.delete(db, i, forgetDecisions: false) }, contains: "forget_decisions")
        try Albums.delete(db, i, forgetDecisions: true)
        #expect(try Albums.list(db) == [])
    }

    @Test func deleteKeepsImages() throws {
        let db = try makeAlbumsDB()
        try db.execute(
            "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            + " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
            + " VALUES (1, '/p/1.jpg', '/p', 'a', 'a', 'jpg', 1, 't', 's', '{}', '{}', 't')", [])
        let i = try Albums.create(db, title: "t", sources: ["/p"], runId: nil, targetCount: 24)
        try db.execute("INSERT INTO album_photos VALUES (?, 1, 0, 't')", [.integer(i)])
        try Albums.delete(db, i, forgetDecisions: false)
        func count(_ t: String) throws -> SQLValue? { try db.query("SELECT COUNT(*) AS n FROM \(t)", []).first?["n"] }
        #expect(try count("images") == .integer(1))
        #expect(try count("album_sources") == .integer(0))
        #expect(try count("album_photos") == .integer(0))
    }

    @Test func requireDraft() throws {
        let db = try makeAlbumsDB()
        let i = try Albums.create(db, title: "t", sources: ["/p"], runId: nil, targetCount: 24)
        try Albums.requireDraft(db, i)
        _ = try Albums.setStatus(db, i, "ordered")
        expectInvalid({ try Albums.requireDraft(db, i) }, contains: "Альбом заказан")
    }

    @Test func attachRun() throws {
        let db = try makeAlbumsDB()
        let i = try Albums.create(db, title: "t", sources: ["/p"], runId: "r1", targetCount: 24)
        #expect(try Albums.attachRun(db, runId: "r2", sources: ["/p"]) == i)
        #expect(try Albums.get(db, i)["run_id"] == "r2")
        _ = try Albums.setStatus(db, i, "ordered")
        let j = try Albums.attachRun(db, runId: "r1", sources: ["/p"])
        #expect(j != i)
        let a = try Albums.get(db, j)
        #expect(a["title"] == "p" && a["run_id"] == "r1")
        #expect(try Albums.get(db, i)["run_id"] == "r2")
    }

    @Test func listOrderAndRename() throws {
        let db = try makeAlbumsDB()
        let a = try Albums.create(db, title: "a", sources: ["/a"], runId: nil, targetCount: 24)
        let b = try Albums.create(db, title: "b", sources: ["/b"], runId: nil, targetCount: 24)
        _ = try Albums.setStatus(db, a, "ordered")
        let ids = try Albums.list(db).arrayValue!.map { $0["id"]!.intValue! }
        #expect(ids == [b, a])
        #expect(try Albums.rename(db, b, title: "  Новое ")["title"] == "Новое")
        expectInvalid({ _ = try Albums.rename(db, b, title: "  ") })
    }
}
