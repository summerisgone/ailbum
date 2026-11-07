import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private func tmpDir() throws -> String {
    let dir = NSTemporaryDirectory() + "ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return Catalog.resolve(dir)
}

private func meta(_ root: String, _ name: String, _ sha: String) -> ImageMetadata {
    ImageMetadata(
        path: root + "/" + name, sourceRoot: root, relativePath: name, fileName: name,
        extension: ".jpg", fileSizeBytes: 1, modifiedAt: "t", createdAt: nil, sha256: sha,
        mimeType: nil, imageFormat: nil, colorMode: nil, width: 1, height: 1,
        frameCount: 1, orientation: nil, takenAt: nil, cameraMake: nil, cameraModel: nil,
        lensModel: nil, software: nil, gpsLatitude: nil, gpsLongitude: nil,
        gpsAltitude: nil, exif: [:], containerMetadata: [:], extractionError: nil)
}

private struct Row: Equatable { var id: Int; var path: String; var availability: String }

private func state(_ db: String) throws -> [Row] {
    let c = try Database.open(path: db)
    return try c.query("SELECT id, path, availability FROM images ORDER BY id", []).map {
        guard case .integer(let i)? = $0["id"], case .text(let p)? = $0["path"],
              case .text(let a)? = $0["availability"] else { fatalError() }
        return Row(id: Int(i), path: p, availability: a)
    }
}

@Test func testPresentToMissing() throws {
    let dir = try tmpDir()
    let db = dir + "/d.sqlite3", root = dir + "/a"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    _ = try Catalog.indexMetadata(database: db, source: root, metadata: [meta(root, "1.jpg", "s1"), meta(root, "2.jpg", "s2")])
    _ = try Catalog.indexMetadata(database: db, source: root, metadata: [meta(root, "1.jpg", "s1")])
    #expect(try state(db).map(\.availability) == ["present", "missing"])
    _ = try Catalog.indexMetadata(database: db, source: root, metadata: [meta(root, "1.jpg", "s1"), meta(root, "2.jpg", "s2")])
    #expect(try state(db).map(\.availability) == ["present", "present"])
}

@Test func testIndexNeverTouchesArchived() throws {
    let dir = try tmpDir()
    let db = dir + "/d.sqlite3", root = dir + "/a"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    _ = try Catalog.indexMetadata(database: db, source: root, metadata: [meta(root, "1.jpg", "s1")])
    let c = try Database.open(path: db)
    try c.execute("UPDATE images SET availability = 'archived'", [])
    try Catalog.markSourceMissing(c, sourceRoot: root)
    #expect(try state(db)[0].availability == "archived")
    _ = try Catalog.indexMetadata(database: db, source: root, metadata: [])
    #expect(try state(db)[0].availability == "archived")
}

@Test func testShaMatchRelinksSingle() throws {
    let dir = try tmpDir()
    let db = dir + "/d.sqlite3", a = dir + "/a", b = dir + "/b"
    _ = try Catalog.indexMetadata(database: db, source: a, metadata: [meta(a, "1.jpg", "X")])
    try Database.open(path: db).execute("UPDATE images SET availability = 'archived'", [])
    _ = try Catalog.indexMetadata(database: db, source: b, metadata: [meta(b, "1.jpg", "X")])
    #expect(try state(db) == [Row(id: 1, path: b + "/1.jpg", availability: "present")])
}

@Test func testShaTwoMatchesNewRow() throws {
    let dir = try tmpDir()
    let db = dir + "/d.sqlite3", a = dir + "/a", b = dir + "/b"
    _ = try Catalog.indexMetadata(database: db, source: a, metadata: [meta(a, "1.jpg", "X"), meta(a, "2.jpg", "X")])
    try Database.open(path: db).execute("UPDATE images SET availability = 'archived'", [])
    _ = try Catalog.indexMetadata(database: db, source: b, metadata: [meta(b, "3.jpg", "X")])
    let rows = try state(db)
    #expect(rows.count == 3)
    #expect(rows[2].path == b + "/3.jpg" && rows[2].availability == "present")
}

@Test func testSummaryCountsAvailability() throws {
    let dir = try tmpDir()
    let db = dir + "/d.sqlite3", root = dir + "/a"
    _ = try Catalog.indexMetadata(database: db, source: root, metadata: (0..<3).map { meta(root, "\($0).jpg", "s\($0)") })
    let c = try Database.open(path: db)
    try c.execute("UPDATE images SET availability = 'archived' WHERE id = 1", [])
    try c.execute("UPDATE images SET availability = 'missing' WHERE id = 2", [])
    // database_summary's availability = GROUP BY availability counts
    let rows = try c.query("SELECT availability, COUNT(*) AS n FROM images GROUP BY availability", [])
    var counts: [String: Int64] = [:]
    for r in rows { if case .text(let a)? = r["availability"], case .integer(let n)? = r["n"] { counts[a] = n } }
    #expect(counts == ["present": 1, "missing": 1, "archived": 1])
}

@Test func testIndexLibraryCreatesQueryableCatalog() throws {
    let dir = try tmpDir()
    let source = dir + "/photos"
    try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let url = URL(fileURLWithPath: source + "/sample.jpg")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    let db = dir + "/catalog.sqlite3"
    var ticks: [[Int]] = []
    let result = try Catalog.indexLibrary(source: source, database: db, recursive: true) { ticks.append([$0, $1]) }
    #expect(result == ["images": 1, "available": 1, "errors": 0])
    #expect(ticks == [[1, 1]])
    let rows = try Database.open(path: db).query("SELECT path, exif_json FROM images", [])
    #expect(rows.count == 1)
    #expect(rows[0]["path"] == .text(source + "/sample.jpg"))
    #expect(throws: AilbumError.invalid("No supported images found in \(dir)/none")) {
        try Catalog.indexLibrary(source: dir + "/none", database: db)
    }
}
