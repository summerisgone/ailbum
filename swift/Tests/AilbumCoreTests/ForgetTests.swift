import Foundation
import Testing
@testable import AilbumCore

private func emb(_ v: [Float]) -> SQLValue { .blob(Vectors.encode(v)!) }

private func makeForgetDB() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/db.sqlite3"
    let c = try Database.open(path: path)
    for (i, root) in [(1, "/a"), (2, "/a"), (3, "/b")] {
        try c.execute(
            "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            + " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,"
            + " indexed_at, availability) VALUES (?, ?, ?, 'x', 'x', '.jpg', 1, 't', ?, '{}',"
            + " '{}', 't', ?)",
            [.integer(i), .text("\(root)/\(i).jpg"), .text(root), .text("sha\(i)"),
             .text(i == 2 ? "archived" : "present")])
    }
    try c.execute("INSERT INTO analysis_runs VALUES ('r', '/a', 'o', 't', 't', 'c', '{}', '{}', 'completed')", [])
    for i in [1, 2] {
        try c.execute(
            "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,"
            + " quality, is_blurry, selected) VALUES ('r', ?, ?, 1, 1, 1, 0, 1)",
            [.integer(i), .text("p\(i)")])
    }
    for (pid, vec) in [(1, [Float(1), 0]), (2, [0, 1])] {
        try c.execute(
            "INSERT INTO people (id, public_id, embedding_model, centroid_embedding,"
            + " embedding_dim, created_at, updated_at) VALUES (?, ?, 'm', ?, 2, 't', 't')",
            [.integer(pid), .text("u\(pid)"), emb(vec)])
    }
    for (fid, img, pid, vec) in [(1, 1, 1, [Float(1), 0]), (2, 3, 1, [0, 1]), (3, 2, 2, [0, 1])] {
        try c.execute(
            "INSERT INTO faces (id, run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
            + " bbox_width, bbox_height, confidence, person_id, embedding, embedding_dim,"
            + " embedding_model) VALUES (?, 'r', ?, ?, 1, 0, 0, 1, 1, .9, ?, ?, 2, 'm')",
            [.integer(fid), .integer(img), .text("f\(fid)"), .integer(pid), emb(vec)])
    }
    let a = try Albums.create(c, title: "Лето", sources: ["/a"], runId: "r", targetCount: 24)
    try c.execute("INSERT INTO album_photos VALUES (?, 1, 1, 't')", [.integer(a)])
    try c.execute(
        "INSERT INTO selection_events (album_id, run_id, image_id, action, source, created_at)"
        + " VALUES (?, 'r', 1, 'add', 'manual', 't')", [.integer(a)])
    for rel in ["photos/sha1.jpg", "photos/sha2.jpg", "photos/sha3.jpg", "faces/1.jpg", "faces/3.jpg", "faces/2.jpg"] {
        let f = dir + "/proxies/" + rel
        try FileManager.default.createDirectory(
            atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("xx".utf8).write(to: URL(fileURLWithPath: f))
    }
    return path
}

private func ids(_ db: Database, _ sql: String) throws -> [Int] {
    try db.query(sql, []).compactMap { r in
        if case .integer(let v)? = r.values.first { return Int(v) }
        return nil
    }
}

private func exists(_ db: String, _ rel: String) -> Bool {
    FileManager.default.fileExists(atPath: (db as NSString).deletingLastPathComponent + "/proxies/" + rel)
}

@Suite struct ForgetTests {
    @Test func bareDatabaseNameResolvesToCurrentDirectory() {
        #expect(Forget.parent("ailbum.sqlite3") == ".")
        #expect(Forget.parent("/x/y/ailbum.sqlite3") == "/x/y")
    }

    @Test func exactlyOneScope() throws {
        let p = try makeForgetDB()
        #expect(throws: AilbumError.invalid("Укажите ровно одно: альбом или источник")) {
            try Forget.plan(database: p, albumId: nil, source: nil)
        }
        #expect(throws: AilbumError.invalid("Укажите ровно одно: альбом или источник")) {
            try Forget.plan(database: p, albumId: 1, source: "/a")
        }
    }

    @Test func planHasNoWrites() throws {
        let p = try makeForgetDB()
        let plan = try Forget.plan(database: p, albumId: nil, source: "/a")
        #expect(plan["images"] == .int(2) && plan["faces"] == .int(2))
        #expect(plan["people_affected"] == [1, 2] && plan["people_removed"] == [2])
        #expect(plan["albums_affected"] == [["id": 1, "title": "Лето"]])
        #expect(plan["events"] == .int(1) && plan["proxies"] == .int(4))
        let c = try Database.open(path: p)
        #expect(try ids(c, "SELECT COUNT(*) FROM images") == [3])
    }

    @Test func forgetSource() throws {
        let p = try makeForgetDB()
        let result = try Forget.forget(database: p, albumId: nil, source: "/a")
        #expect(result["done"] == .bool(true))
        let c = try Database.open(path: p)
        #expect(try ids(c, "SELECT id FROM images") == [3])
        #expect(try ids(c, "SELECT id FROM people") == [1])
        #expect(try ids(c, "SELECT COUNT(*) FROM album_photos") == [0])
        #expect(try ids(c, "SELECT COUNT(*) FROM selection_events") == [0])
        #expect(try ids(c, "SELECT COUNT(*) FROM albums") == [1])
        let row = try c.query("SELECT centroid_embedding FROM people WHERE id = 1", [])
        guard case .blob(let blob)? = row.first?["centroid_embedding"] else { Issue.record("no centroid"); return }
        let centroid = Vectors.decode(blob, dimension: 2)
        #expect(abs(centroid[0]) < 1e-6 && abs(centroid[1] - 1) < 1e-6)
        #expect(!exists(p, "photos/sha1.jpg") && !exists(p, "faces/1.jpg"))
        #expect(exists(p, "photos/sha3.jpg") && exists(p, "faces/2.jpg"))
    }

    @Test func forgetAlbumDeletesAlbum() throws {
        let p = try makeForgetDB()
        _ = try Forget.forget(database: p, albumId: 1, source: nil)
        let c = try Database.open(path: p)
        #expect(try ids(c, "SELECT COUNT(*) FROM albums") == [0])
        #expect(try ids(c, "SELECT id FROM images") == [3])
    }

    @Test func sharedShaKeepsPhotoProxy() throws {
        let p = try makeForgetDB()
        try Database.open(path: p).execute("UPDATE images SET sha256 = 'sha1' WHERE id = 3", [])
        _ = try Forget.forget(database: p, albumId: nil, source: "/a")
        #expect(exists(p, "photos/sha1.jpg"))
    }

    @Test func usage() throws {
        let p = try makeForgetDB()
        let cache = (p as NSString).deletingLastPathComponent + "/feature-cache"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try Data("123".utf8).write(to: URL(fileURLWithPath: cache + "/a.npz"))
        let u = try Forget.usage(database: p)
        #expect(u["proxies_bytes"] == .int(12) && u["feature_cache_bytes"] == .int(3))
        #expect((u["database_bytes"]?.intValue ?? 0) > 0)
        #expect(u["images"] == ["present": 2, "missing": 0, "archived": 1])
    }
}
