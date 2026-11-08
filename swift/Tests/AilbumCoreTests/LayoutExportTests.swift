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
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-lx-\(UUID().uuidString)"
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
private func addImage(_ e: Env, _ n: Int) throws -> String {
    let path = e.src + "/фото \(n).jpg"
    try writeJPEG(path)
    try e.db.execute(
        "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
        + " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
        + " VALUES (?, ?, ?, 'a', ?, 'jpg', 1, 't', ?, '{}', '{}', 't')",
        [.integer(n), .text(path), .text(e.src), .text("фото \(n).jpg"), .text("sha\(n)")])
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

@Suite struct LayoutExportTests {
    @Test func exportLogsAndSkipsMissing() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        try addImage(e, 2)
        try e.db.execute("UPDATE images SET availability='missing' WHERE id=2", [])
        let a = try makeAlbum(e, [1, 2])
        let out = e.dir + "/Выгрузка"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let r = try LayoutExport.exportOriginals(database: e.dbPath, albumId: a, folder: out)
        #expect(r["count"]?.intValue == 1)
        #expect(r["missing"]?.arrayValue?.count == 1)
        #expect((r["export_id"]?.intValue ?? 0) > 0)
        let row = try e.db.query("SELECT * FROM album_exports", [])[0]
        guard case .text(let json)? = row["missing_json"] else { Issue.record("no missing_json"); return }
        #expect(try JSONValue.parse(json) == r["missing"])
        #expect(row["selection_hash"] == .text(try AlbumLibrary.selectionHash(e.db, albumId: a)))
        #expect(row["folder"] == .text(r["folder"]?.stringValue ?? ""))
        #expect(row["layout_id"] != .null)
        let names = try FileManager.default.contentsOfDirectory(atPath: r["folder"]!.stringValue!)
        #expect(names == ["01-1_фото 1.jpg"])
        #expect(r["folder"]?.stringValue == out + "/" + LayoutExport.exportDir)
    }

    @Test func exportPrepareNeedsExportThenTrash() throws {
        let e = try makeEnv()
        let p1 = try addImage(e, 1)
        let a = try makeAlbum(e, [1])
        var r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["needs_export"] == .bool(true))
        #expect(r["trash"]?.arrayValue?.isEmpty == true)
        #expect(try Albums.get(e.db, a)["status"]?.stringValue == "ordered")
        _ = try LayoutExport.exportOriginals(database: e.dbPath, albumId: a, folder: e.dir)
        r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["needs_export"] == .bool(false))
        #expect(r["trash"]?.arrayValue == [.string(p1)])
        #expect(r["blocked"]?.arrayValue?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: e.dir + "/db/proxies/photos/sha1.jpg"))
    }

    @Test func exportPrepareBuildsFaceProxies() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        let a = try makeAlbum(e, [1])
        try e.db.execute(
            "INSERT INTO faces (id, run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
            + " bbox_width, bbox_height, confidence) VALUES (7, 'r1', 1, 'f', 0, 10, 10, 20, 20, 1)", [])
        _ = try LayoutExport.exportOriginals(database: e.dbPath, albumId: a, folder: e.dir)
        let r = try Archive.prepare(database: e.dbPath, albumId: a)
        #expect(r["blocked"]?.arrayValue?.isEmpty == true)
        #expect(r["trash"]?.arrayValue?.count == 1)
        #expect(FileManager.default.fileExists(atPath: e.dir + "/db/proxies/faces/7.jpg"))
    }

    @Test func exportWithoutLayoutThrows() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        let a = try makeAlbum(e, [1], layout: false)
        #expect(throws: AilbumError.invalid("Раскладка не создана")) {
            try LayoutExport.exportOriginals(database: e.dbPath, albumId: a, folder: e.dir)
        }
    }

    @Test func testUniqueNameSuffix() throws {
        let e = try makeEnv()
        try addImage(e, 1)
        let a = try makeAlbum(e, [1])
        let taken = e.dir + "/" + LayoutExport.exportDir
        try FileManager.default.createDirectory(atPath: taken, withIntermediateDirectories: true)
        let r = try LayoutExport.exportOriginals(database: e.dbPath, albumId: a, folder: e.dir)
        #expect(r["folder"]?.stringValue == taken + " 2")
        let again = try LayoutExport.exportOriginals(database: e.dbPath, albumId: a, folder: e.dir)
        #expect(again["folder"]?.stringValue == taken + " 3")
    }
}
