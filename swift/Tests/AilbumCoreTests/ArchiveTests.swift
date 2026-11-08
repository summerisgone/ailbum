import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private struct Env {
    let dir: String
    let dbPath: String
    let src: String
    let db: Database
}

private func makeEnv() throws -> Env {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-ar-\(UUID().uuidString)"
    let src = dir + "/Мои фото"
    try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: dir + "/db", withIntermediateDirectories: true)
    let path = dir + "/db/a.sqlite"
    let db = try Database.open(path: path)
    try db.execute("INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','x','{}','{}','completed')", [])
    return Env(dir: dir, dbPath: path, src: src, db: db)
}

private func writeJPEG(_ path: String) throws {
    let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    try (data as Data).write(to: URL(fileURLWithPath: path))
}

@discardableResult
private func addImage(_ e: Env, _ n: Int, sha: String? = nil) throws -> String {
    let path = e.src + "/фото \(n).jpg"
    try writeJPEG(path)
    try e.db.execute(
        "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
        + " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
        + " VALUES (?, ?, ?, 'a', ?, 'jpg', 1, 't', ?, '{}', '{}', 't')",
        [.integer(n), .text(path), .text(e.src), .text("фото \(n).jpg"), .text(sha ?? "sha\(n)")])
    return path
}

private func makeAlbum(_ e: Env, _ ids: [Int], title: String = "Альбом", layout: Bool = true) throws -> Int {
    let a = try Albums.create(e.db, title: title, sources: ["/p"], runId: "r1", targetCount: 24)
    for (pos, i) in ids.enumerated() {
        try e.db.execute("INSERT INTO album_photos VALUES (?, ?, ?, 't')", [.integer(a), .integer(i), .integer(pos)])
    }
    if layout {
        try e.db.execute(
            "INSERT INTO layouts (album_id, run_id, orientation, spread_count, min_photos,"
            + " max_photos, selection_hash, created_at, updated_at)"
            + " VALUES (?, 'r1', 'landscape', 1, 1, 4, 'h', 't', 't')", [.integer(a)])
        let layoutId = try e.db.query("SELECT last_insert_rowid() AS id", [])[0]["id"]!
        try e.db.execute("INSERT INTO layout_spreads (layout_id, position, template_id) VALUES (?, 1, 't')", [layoutId])
        let spreadId = try e.db.query("SELECT last_insert_rowid() AS id", [])[0]["id"]!
        for (cell, i) in ids.enumerated() {
            try e.db.execute(
                "INSERT INTO layout_placements (spread_id, cell_index, image_id, crop_x, crop_y,"
                + " crop_w, crop_h, fit) VALUES (?, ?, ?, 0, 0, 1, 1, 1)",
                [spreadId, .integer(cell), .integer(i)])
        }
    }
    return a
}

/// Stands in for export_originals: records a clean export of the current selection.
private func fakeExport(_ e: Env, _ albumId: Int, missing: String = "[]") throws {
    let hash = try Archive.selectionHash(e.db, albumId)
    try e.db.execute(
        "INSERT INTO album_exports (album_id, selection_hash, folder, count, missing_json, exported_at)"
        + " VALUES (?, ?, '/x', 1, ?, 't')", [.integer(albumId), .text(hash), .text(missing)])
}

private func availability(_ e: Env, _ id: Int) throws -> String? {
    if case .text(let s)? = try e.db.query("SELECT availability FROM images WHERE id = ?", [.integer(id)]).first?["availability"] {
        return s
    }
    return nil
}

private func strings(_ v: JSONValue?) -> [String] { v?.arrayValue?.compactMap { $0.stringValue } ?? [] }

@Suite struct ArchiveTests {
    @Test func prepareNeedsExportThenTrash() throws {
        let e = try makeEnv()
        let p1 = try addImage(e, 1)
        let a = try makeAlbum(e, [1])
        var r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["needs_export"] == true && r["trash"] == [])
        #expect(try Albums.get(e.db, a)["status"] == "ordered")
        try fakeExport(e, a)
        r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["needs_export"] == false && strings(r["trash"]) == [p1] && r["blocked"] == [])
        #expect(FileManager.default.fileExists(atPath: e.dir + "/db/proxies/photos/sha1.jpg"))
    }

    @Test func exportWithMissingStillNeedsExport() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        let a = try makeAlbum(e, [1])
        try fakeExport(e, a, missing: "[\"/gone\"]")
        #expect(try Archive.prepare(database: e.dbPath, albumId: a)["needs_export"] == true)
    }

    @Test func prepareArchivedThrows() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        let a = try makeAlbum(e, [1], layout: false)
        _ = try Albums.setStatus(e.db, a, "ordered")
        _ = try Albums.setStatus(e.db, a, "archived")
        do {
            _ = try Archive.prepare(database: e.dbPath, albumId: a)
            Issue.record("expected throw")
        } catch AilbumError.invalid(let m) {
            #expect(m == "Альбом уже в архиве")
        }
    }

    @Test func noLayoutNoExportNeededAndSharedBlocked() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        try addImage(e, 2)
        let a = try makeAlbum(e, [1, 2], title: "Первый", layout: false)
        _ = try makeAlbum(e, [2], title: "Лето", layout: false)
        let r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["needs_export"] == false)
        #expect(r["trash"]?.arrayValue?.count == 1)
        #expect(r["blocked"] == [["image_id": 2, "reason": "входит в черновик «Лето»"]])
    }

    @Test func unbuildableProxyNeverTrashed() throws {
        let e = try makeEnv()
        let p = try addImage(e, 1)
        try Data("not an image".utf8).write(to: URL(fileURLWithPath: p))
        let a = try makeAlbum(e, [1], layout: false)
        let r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["trash"] == [])
        #expect(r["blocked"]?[0]?["reason"]?.stringValue?.hasPrefix("не удалось построить превью") == true)
    }

    @Test func completeArchive() throws {
        let e = try makeEnv()
        let p1 = try addImage(e, 1, sha: "same")
        let p2 = try addImage(e, 2, sha: "same")
        let p3 = try addImage(e, 3)
        let a = try makeAlbum(e, [1, 3], layout: false)
        let cache = e.dir + "/db/feature-cache/m"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        for n in ["same", "sha3"] { try Data("x".utf8).write(to: URL(fileURLWithPath: cache + "/\(n).npz")) }
        _ = try Archive.prepare(database: e.dbPath, albumId: a)
        try FileManager.default.removeItem(atPath: p1)
        var r = try Archive.complete(database: e.dbPath, albumId: a, trashed: [p1, p2])
        #expect(r["archived"] == 1 && r["status"] == "ordered")
        #expect(FileManager.default.fileExists(atPath: cache + "/same.npz"))
        try FileManager.default.removeItem(atPath: p3)
        r = try Archive.complete(database: e.dbPath, albumId: a, trashed: [p3])
        #expect(r["status"] == "archived" && r["cache_removed"] == 1)
        #expect(!FileManager.default.fileExists(atPath: cache + "/sha3.npz"))
        #expect(FileManager.default.fileExists(atPath: cache + "/same.npz"))
        #expect(try availability(e, 2) == "present")
    }

    @Test func cacheRemovedWhenNoPresentSameSha() throws {
        let e = try makeEnv()
        let p1 = try addImage(e, 1)
        let a = try makeAlbum(e, [1], layout: false)
        let cache = e.dir + "/db/feature-cache/m"
        try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: cache + "/sha1.npz"))
        _ = try Archive.prepare(database: e.dbPath, albumId: a)
        try FileManager.default.removeItem(atPath: p1)
        #expect(try Archive.complete(database: e.dbPath, albumId: a, trashed: [p1])["cache_removed"] == 1)
    }

    @Test func trashPathsBackend() {
        var calls: [String] = []
        Archive.trasher = { path in
            calls.append(path)
            if path.hasSuffix("bad") { throw AilbumError.invalid("x") }
        }
        defer { Archive.trasher = nil }
        #expect(Archive.trashPaths(["/t/a b", "/t/bad", "/t/ё"]) == ["/t/a b", "/t/ё"])
        #expect(calls == ["/t/a b", "/t/bad", "/t/ё"])
    }

    @Test func confirmMissing() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        try addImage(e, 2)
        try e.db.execute("UPDATE images SET availability='missing' WHERE id=1", [])
        #expect(try Archive.confirmMissing(database: e.dbPath, imageIds: [1, 2]) == 1)
        #expect(try availability(e, 1) == "archived")
        #expect(try availability(e, 2) == "present")
        #expect(try Archive.confirmMissing(database: e.dbPath, imageIds: []) == 0)
    }

    @Test func prepareBuildsFaceProxies() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        let a = try makeAlbum(e, [1])
        try e.db.execute(
            "INSERT INTO faces (id, run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
            + " bbox_width, bbox_height, confidence) VALUES (7, 'r1', 1, 'f', 0, 10, 10, 20, 20, 1)", [])
        try fakeExport(e, a)
        let r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["blocked"] == [] && r["trash"]?.arrayValue?.count == 1)
        #expect(FileManager.default.fileExists(atPath: e.dir + "/db/proxies/faces/7.jpg"))
    }
}
