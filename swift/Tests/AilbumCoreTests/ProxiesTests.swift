import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private func tempDir() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-px-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private typealias ImageRow = (Int, String, String, String, Int, Int, Int)

private func makeDB(_ dir: String, images: [ImageRow], faces: [(Int, Int, Int, Int, Int, Int)] = []) throws -> String {
    let path = dir + "/db/a.sqlite"
    try FileManager.default.createDirectory(atPath: dir + "/db", withIntermediateDirectories: true)
    let db = try Database(path: path)
    try db.execute(
        "CREATE TABLE images (id INTEGER PRIMARY KEY, path TEXT, sha256 TEXT, availability TEXT,"
        + " width INTEGER, height INTEGER, orientation INTEGER)", [])
    try db.execute(
        "CREATE TABLE faces (id INTEGER PRIMARY KEY, image_id INTEGER, bbox_x INTEGER,"
        + " bbox_y INTEGER, bbox_width INTEGER, bbox_height INTEGER)", [])
    for i in images {
        try db.execute("INSERT INTO images VALUES (?,?,?,?,?,?,?)",
                       [.integer(i.0), .text(i.1), .text(i.2), .text(i.3), .integer(i.4), .integer(i.5), .integer(i.6)])
    }
    for f in faces {
        try db.execute("INSERT INTO faces VALUES (?,?,?,?,?,?)",
                       [.integer(f.0), .integer(f.1), .integer(f.2), .integer(f.3), .integer(f.4), .integer(f.5)])
    }
    try db.executeScript("PRAGMA user_version = 12")
    return path
}

private func writeJPEG(_ path: String, width: Int, height: Int, orientation: Int? = nil,
                       color: (UInt8, UInt8, UInt8) = (200, 30, 30), patch: (CGRect, (UInt8, UInt8, UInt8))? = nil) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func fill(_ c: (UInt8, UInt8, UInt8), _ r: CGRect) {
        ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        ctx.fill(r)
    }
    fill(color, CGRect(x: 0, y: 0, width: width, height: height))
    if let patch { fill(patch.1, patch.0) }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [:]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    try (data as Data).write(to: URL(fileURLWithPath: path))
}

private func size(of path: String) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
}

private func tmpFiles(_ dir: String) -> [String] {
    ((FileManager.default.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(".tmp") }
}

@Suite struct ProxiesTests {
    @Test func buildResizesAndReuses() throws {
        let dir = try tempDir()
        let src = dir + "/Мои фото/а б.jpg"
        try writeJPEG(src, width: 3000, height: 2000)
        let db = try makeDB(dir, images: [(1, src, "ab", "present", 3000, 2000, 1)], faces: [(7, 1, 100, 100, 200, 200)])
        let result = try Proxies.build(database: db, imageIds: [1])
        #expect(result == ["built": [1], "failed": []])
        let s = size(of: dir + "/db/proxies/photos/ab.jpg")
        #expect(s?.0 == 1600 && s?.1 == 1067)
        let f = size(of: dir + "/db/proxies/faces/7.jpg")
        #expect(f?.0 == 240 && f?.1 == 240)
        try FileManager.default.removeItem(atPath: src)
        let conn = try Database(path: db)
        try conn.execute("UPDATE images SET availability='archived'", [])
        #expect(try Proxies.build(database: db, imageIds: [1])["built"] == [1])
    }

    @Test func exifOrientation6Rotates() throws {
        let dir = try tempDir()
        let src = dir + "/r.jpg"
        try writeJPEG(src, width: 400, height: 200, orientation: 6)
        let db = try makeDB(dir, images: [(1, src, "r", "present", 400, 200, 6)])
        _ = try Proxies.build(database: db, imageIds: [1])
        let s = size(of: dir + "/db/proxies/photos/r.jpg")
        #expect(s?.0 == 200 && s?.1 == 400)
    }

    @Test func failedWhenMissingAndNoProxy() throws {
        let dir = try tempDir()
        let db = try makeDB(dir, images: [(1, dir + "/no.jpg", "n", "missing", 1, 1, 1)])
        let result = try Proxies.build(database: db, imageIds: [1, 99])
        #expect(result["built"] == [])
        let ids = result["failed"]?.arrayValue?.compactMap { $0["image_id"]?.intValue }
        #expect(ids == [1, 99])
        #expect(tmpFiles(dir).isEmpty)
    }

    @Test func buildEmpty() throws {
        let dir = try tempDir()
        let db = dir + "/db/none.sqlite"
        #expect(try Proxies.build(database: db, imageIds: []) == ["built": [], "failed": []])
        #expect(Proxies.photoProxy(database: "/x/catalog.sqlite3", sha256: "ab") == "/x/proxies/photos/ab.jpg")
    }

    @Test func imageSource() throws {
        let dir = try tempDir()
        let src = dir + "/x.jpg"
        try writeJPEG(src, width: 50, height: 50)
        let db = try makeDB(dir, images: [])
        let row: [String: SQLValue] = ["path": .text(src), "sha256": .text("ab"), "availability": .text("present")]
        #expect(Proxies.imageSource(database: db, image: row) == src)
        let gone: [String: SQLValue] = ["path": .text(dir + "/g.jpg"), "sha256": .text("ab"), "availability": .text("archived")]
        #expect(Proxies.imageSource(database: db, image: gone) == nil)
        let proxy = dir + "/db/proxies/photos/ab.jpg"
        try writeJPEG(proxy, width: 10, height: 10)
        #expect(Proxies.imageSource(database: db, image: gone) == proxy)
    }

    @Test func faceThumbnailFromProxyScaled() throws {
        let dir = try tempDir()
        let src = dir + "/f.jpg"
        // CG origin is bottom-left: image rows 400..800 from top map to y 200..600.
        try writeJPEG(src, width: 2000, height: 1000, color: (0, 0, 255),
                      patch: (CGRect(x: 1000, y: 200, width: 400, height: 400), (255, 0, 0)))
        let db = try makeDB(dir, images: [(1, src, "f", "present", 2000, 1000, 1)], faces: [(3, 1, 1000, 400, 400, 400)])
        _ = try Proxies.build(database: db, imageIds: [1])
        try FileManager.default.removeItem(atPath: dir + "/db/proxies/faces/3.jpg")
        try FileManager.default.removeItem(atPath: src)
        let conn = try Database(path: db)
        try conn.execute("UPDATE images SET availability='archived'", [])
        let data = try Proxies.faceThumbnail(database: db, faceId: 3)
        let tmp = dir + "/thumb.jpg"
        try data.write(to: URL(fileURLWithPath: tmp))
        #expect(size(of: tmp)?.0 == 240 && size(of: tmp)?.1 == 240)
        let img = try ImageLoader.load(path: tmp)
        let i = (120 * 240 + 120) * 3
        #expect(img.pixels[i] > 200 && img.pixels[i + 2] < 60)
    }

    @Test func faceThumbnailUnknown() throws {
        let dir = try tempDir()
        let db = try makeDB(dir, images: [])
        #expect(throws: AilbumError.self) { try Proxies.faceThumbnail(database: db, faceId: 1) }
    }

    @Test func imageSourceAcceptsSqliteRow() throws {
        let dir = try tempDir()
        let src = dir + "/r.jpg"
        try writeJPEG(src, width: 50, height: 50)
        let db = try makeDB(dir, images: [])
        let mem = try Database(path: ":memory:")
        let row = try mem.query("SELECT ? AS path, 'ab' AS sha256, 'present' AS availability", [.text(src)])[0]
        #expect(Proxies.imageSource(database: db, image: row) == src)
    }
}
