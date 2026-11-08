import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import Testing
@testable import AilbumCore

private final class FakeDetector: @unchecked Sendable {
    var objects: [DetectedObject]
    var calls = 0
    init(_ objects: [DetectedObject] = []) { self.objects = objects }
    var closure: (RGBImage) throws -> [DetectedObject] {
        { [self] image in
            #expect(image.pixels.count == image.width * image.height * 3)
            calls += 1
            return objects
        }
    }
}

private func dog() -> DetectedObject {
    DetectedObject(label: "dog", score: 0.8, bbox: SIMD4<Float>(0.1, 0.1, 0.4, 0.4))
}

private func writeFactsJPEG(_ path: String, width: Int = 40, height: Int = 30) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func makeFactsDB() throws -> Database {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-lf-\(UUID().uuidString)"
    let db = try Database.open(path: dir + "/db.sqlite3")
    try db.execute("INSERT INTO analysis_runs VALUES ('r','s','o','t','t','dnn','{}','{}','completed')", [])
    try db.execute(
        "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
        + " VALUES (1, 'u1', 'А', 'r', 't', 't')", [])
    return db
}

private func factsDir(_ db: Database) throws -> String {
    guard case .text(let file)? = try db.query("PRAGMA database_list", []).first?["file"] else { return "" }
    return (file as NSString).deletingLastPathComponent
}

private func opt(_ v: Int?) -> SQLValue { v.map { .integer($0) } ?? .null }
private func opt(_ v: Double?) -> SQLValue { v.map { .real($0) } ?? .null }

@discardableResult
private func addImage(
    _ db: Database, _ id: Int, selected: Bool = true, cluster: Int? = nil, blurry: Bool = false,
    width: Int = 40, height: Int = 30, orientation: Int? = nil, exists: Bool = true,
    quality: Double = 0.5, aesthetic: Double? = nil, subject: [Double]? = nil, storyId: Int? = nil,
    sha: String = "sha"
) throws -> String {
    let path = try factsDir(db) + "/\(id).jpg"
    if exists { try writeFactsJPEG(path) }
    try db.execute(
        """
        INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
        file_size_bytes, modified_at, sha256, width, height, orientation, taken_at,
        exif_json, container_metadata_json, indexed_at)
        VALUES (?, ?, 's', ?, ?, '.jpg', 1, 't', ?, ?, ?, ?, ?, '{}', '{}', 't')
        """,
        [.integer(id), .text(path), .text("\(id).jpg"), .text("\(id).jpg"), .text(sha),
         .integer(width), .integer(height), opt(orientation),
         .text("2026-01-01T10:00:" + (id < 10 ? "0\(id)" : "\(id)"))])
    var subjectJSON: SQLValue = .null
    if let subject {
        let box = subject.map { String($0) }.joined(separator: ", ")
        subjectJSON = .text("{\"bbox\": [\(box)], \"center\": [0, 0], \"source\": \"x\"}")
    }
    try db.execute(
        """
        INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,
        aesthetic_score, main_subject_json, is_blurry, similar_cluster, story_id, selected)
        VALUES ('r', ?, ?, 1, 1, ?, ?, ?, ?, ?, ?, 0)
        """,
        [.integer(id), .text("p\(id)"), .real(quality), opt(aesthetic), subjectJSON,
         .integer(blurry ? 1 : 0), opt(cluster), opt(storyId)])
    if selected { try db.execute("INSERT INTO album_photos VALUES (1, ?, ?, 't')", [.integer(id), .integer(id)]) }
    return path
}

private func addFace(
    _ db: Database, _ imageId: Int, _ bbox: [Double], closed: Bool = false, smile: Double? = nil, index: Int = 0
) throws {
    try db.execute(
        """
        INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y, bbox_width,
        bbox_height, confidence, both_eyes_open, smile_probability)
        VALUES ('r', ?, ?, ?, ?, ?, ?, ?, 0.9, ?, ?)
        """,
        [.integer(imageId), .text("f\(imageId)-\(index)"), .integer(index)] + bbox.map { .real($0) }
            + [.integer(closed ? 0 : 1), opt(smile)])
}

private func pool(_ db: Database, _ detector: FakeDetector? = nil,
                  progress: ((Int, Int) -> Void)? = nil) throws -> [PhotoFacts] {
    try Facts.loadPool(db, albumId: 1, detector: detector?.closure, progress: progress)
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite struct LayoutFactsTests {
    @Test func factsBuildRegionsFaceExpansion() {
        let regions = Facts.buildRegions(faces: [(0.4, 0.4, 0.1, 0.1)], objects: [], subject: nil)
        #expect(regions.count == 1)
        #expect(regions[0].hard && regions[0].weight == 1.0)
        let b = regions[0].bbox
        #expect(near(b.x, 0.38) && near(b.y, 0.365) && near(b.w, 0.14) && near(b.h, 0.15))
    }

    @Test func factsBackgroundFaceIsSoft() {
        let regions = Facts.buildRegions(
            faces: [(0.1, 0.1, 0.5, 0.5), (0.8, 0.8, 0.05, 0.05)], objects: [], subject: nil)
        #expect(regions[0].hard)
        #expect(!regions[1].hard && regions[1].weight == 0.2)
        let b = regions[1].bbox
        #expect(near(b.x, 0.8) && near(b.y, 0.8) && near(b.w, 0.05) && near(b.h, 0.05))
    }

    @Test func factsExpandedFaceClippedToImage() {
        let b = Facts.buildRegions(faces: [(0.0, 0.0, 0.2, 0.2)], objects: [], subject: nil)[0].bbox
        #expect(b.x == 0.0 && b.y == 0.0)
    }

    @Test func factsObjectsWeightsAndThreshold() {
        let objects = [
            DetectedObject(label: "person", score: 0.4, bbox: SIMD4<Float>(0.1, 0.1, 0.2, 0.5)),
            DetectedObject(label: "dog", score: 0.6, bbox: SIMD4<Float>(0.5, 0.5, 0.2, 0.2)),
            DetectedObject(label: "cup", score: 0.4, bbox: SIMD4<Float>(0.7, 0.7, 0.1, 0.1)),
        ]
        let regions = Facts.buildRegions(faces: [], objects: objects, subject: nil)
        #expect(regions.map(\.kind) == ["person", "object"])
        #expect(regions.map(\.weight) == [0.6, 0.5])
        #expect(regions.map(\.hard) == [false, false])
    }

    @Test func factsZeroAreaRegionIgnored() {
        let regions = Facts.buildRegions(
            faces: [(0.1, 0.1, 0.0, 0.2)],
            objects: [DetectedObject(label: "dog", score: 0.9, bbox: SIMD4<Float>(0, 0, 0, 0.1))],
            subject: Rect(x: 0.1, y: 0.1, w: 0.0, h: 0.0))
        #expect(regions.isEmpty)
    }

    @Test func factsSaliencyOnlyWithoutFacesAndObjects() {
        let subject = Rect(x: 0.2, y: 0.2, w: 0.3, h: 0.3)
        let only = Facts.buildRegions(faces: [], objects: [], subject: subject)
        #expect(only.map(\.kind) == ["subject"] && only.map(\.weight) == [0.3] && only.map(\.hard) == [false])
        #expect(Facts.buildRegions(faces: [(0.4, 0.4, 0.1, 0.1)], objects: [], subject: subject)
            .allSatisfy { $0.kind != "subject" })
        let weak = [DetectedObject(label: "cup", score: 0.3, bbox: SIMD4<Float>(0.1, 0.1, 0.1, 0.1))]
        #expect(Facts.buildRegions(faces: [], objects: weak, subject: subject)[0].kind == "subject")
    }

    @Test func factsRotatedExifSwapsAspect() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, width: 4000, height: 3000, orientation: 6)
        try addImage(db, 2, width: 4000, height: 3000, orientation: 1)
        let p = Dictionary(uniqueKeysWithValues: try pool(db).map { ($0.imageId, $0) })
        #expect(near(p[1]!.aspect, 0.75))
        #expect(near(p[2]!.aspect, 4.0 / 3.0))
    }

    @Test func factsFaceNormalizedByRotatedSize() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, width: 4000, height: 3000, orientation: 6)
        try addFace(db, 1, [300, 600, 300, 300])
        let region = try pool(db)[0].regions[0]
        #expect(near(region.bbox.x, 0.1 - 0.1 * 0.2))
        #expect(near(region.bbox.y, 0.15 - 0.075 * 0.35))
        #expect(near(region.bbox.w, 0.14))
    }

    @Test func factsMissingFileExcluded() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, exists: false)
        try addImage(db, 2)
        #expect(try pool(db).map(\.imageId) == [2])
    }

    @Test func factsUnitKeysAndStory() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, cluster: 3, storyId: 7)
        try addImage(db, 2)
        let p = Dictionary(uniqueKeysWithValues: try pool(db).map { ($0.imageId, $0) })
        #expect(p[1]!.unitKey == "cluster:3" && p[1]!.storyId == 7)
        #expect(p[1]!.takenAt == "2026-01-01T10:00:01")
        #expect(p[2]!.unitKey == "image:2" && p[2]!.storyId == nil)
        #expect(p[1]!.selected)
    }

    @Test func factsUnselectedSiblingInPool() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, cluster: 3)
        try addImage(db, 2, selected: false, cluster: 3)
        let p = Dictionary(uniqueKeysWithValues: try pool(db).map { ($0.imageId, $0) })
        #expect(Set(p.keys) == [1, 2])
        #expect(!p[2]!.selected)
    }

    @Test func factsBlurrySiblingExcluded() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, cluster: 3)
        try addImage(db, 2, selected: false, cluster: 3, blurry: true)
        #expect(try pool(db).map(\.imageId) == [1])
    }

    @Test func factsUnrelatedUnselectedExcluded() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, cluster: 3)
        try addImage(db, 2, selected: false, cluster: 4)
        try addImage(db, 3, selected: false, cluster: nil)
        #expect(try pool(db).map(\.imageId) == [1])
    }

    @Test func factsRankPenalisesClosedEyes() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, selected: false, cluster: 1, quality: 0.6, aesthetic: 0.4)
        try addImage(db, 2, selected: true, cluster: 1, quality: 0.6, aesthetic: 0.4)
        try addImage(db, 3, selected: true, quality: 0.6, aesthetic: 0.4)
        try addFace(db, 3, [1, 1, 5, 5], closed: true, smile: 0.9)
        try addImage(db, 4, selected: true, quality: 0.6, aesthetic: 0.4)
        try addFace(db, 4, [1, 1, 5, 5], smile: 0.9)
        let p = Dictionary(uniqueKeysWithValues: try pool(db).map { ($0.imageId, $0) })
        let base = 0.45 * 0.6 + 0.35 * 0.4
        #expect(near(p[1]!.rank, base))
        #expect(near(p[2]!.rank, base + 0.2))
        #expect(near(p[4]!.rank, base + 0.1 + 0.2))
        #expect(near(p[3]!.rank, base + 0.1))
        #expect(p[3]!.rank < p[4]!.rank)
    }

    @Test func factsRankMatchesPythonGolden() throws {
        let db = try makeFactsDB()
        try addImage(db, 5, selected: true, quality: 0.6, aesthetic: 0.8)
        try addFace(db, 5, [1, 1, 5, 5], smile: 0.9, index: 0)
        try addFace(db, 5, [10, 1, 5, 5], smile: 0.5, index: 1)
        try addFace(db, 5, [20, 1, 5, 5], closed: true, smile: nil, index: 2)
        try addImage(db, 6, selected: true, cluster: 3, quality: 0.6, aesthetic: nil)
        try addImage(db, 7, selected: false, cluster: 3, quality: 0.6, aesthetic: nil)
        try addFace(db, 7, [1, 1, 5, 5], smile: 0.9, index: 0)
        try addFace(db, 7, [10, 1, 5, 5], smile: 0.2, index: 1)
        let p = Dictionary(uniqueKeysWithValues: try pool(db).map { ($0.imageId, $0) })
        // Python _rank goldens: 0.6166666666666667 and 0.53.
        #expect(near(p[5]!.rank, 0.6166666666666667))
        #expect(near(p[7]!.rank, 0.53))
    }

    @Test func factsRankClamped() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, quality: 1.0, aesthetic: 1.0)
        try addFace(db, 1, [1, 1, 5, 5], smile: 1.0)
        #expect(try pool(db)[0].rank == 1.0)
    }

    @Test func factsSaliencyUsedFromDatabase() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, subject: [0.2, 0.2, 0.3, 0.3])
        let region = try pool(db)[0].regions[0]
        #expect(region.kind == "subject" && region.bbox == Rect(x: 0.2, y: 0.2, w: 0.3, h: 0.3))
    }

    @Test func factsDetectorResultsCached() throws {
        let db = try makeFactsDB()
        try addImage(db, 1)
        let detector = FakeDetector([dog()])
        let first = try pool(db, detector)
        #expect(detector.calls == 1)
        #expect(first[0].regions[0].kind == "object")
        let again = try pool(db, detector)
        #expect(detector.calls == 1)
        #expect(again[0].regions == first[0].regions)
        #expect(try pool(db)[0].regions == first[0].regions)
        let row = try db.query("SELECT detector_model FROM image_object_scans", []).first
        #expect(row?["detector_model"] == .text(Facts.detectorModel))
        #expect(Facts.detectorModel == "yolox_s_2022nov")
    }

    @Test func factsCachedScanNotRerunWithProgress() throws {
        let db = try makeFactsDB()
        try addImage(db, 1)
        try addImage(db, 2)
        let detector = FakeDetector()
        var seen: [[Int]] = []
        _ = try pool(db, detector) { seen.append([$0, $1]) }
        #expect(detector.calls == 2)
        #expect(seen.last == [2, 2])
    }

    @Test func factsScanRerunWhenShaChanges() throws {
        let db = try makeFactsDB()
        try addImage(db, 1)
        let detector = FakeDetector()
        _ = try pool(db, detector)
        try db.execute("UPDATE images SET sha256 = 'other' WHERE id = 1", [])
        _ = try pool(db, detector)
        #expect(detector.calls == 2)
        #expect(try db.query("SELECT sha256 FROM image_object_scans", []).first?["sha256"] == .text("other"))
    }

    @Test func factsStaleScanIgnoredWithoutDetector() throws {
        let db = try makeFactsDB()
        try addImage(db, 1)
        _ = try pool(db, FakeDetector([dog()]))
        try db.execute("UPDATE images SET sha256 = 'other' WHERE id = 1", [])
        #expect(try pool(db)[0].regions.isEmpty)
    }

    @Test func factsUnreadableImageDoesNotAbort() throws {
        let db = try makeFactsDB()
        let path = try addImage(db, 1)
        try Data("not an image".utf8).write(to: URL(fileURLWithPath: path))
        try addImage(db, 2)
        let detector = FakeDetector()
        let p = try pool(db, detector)
        #expect(p.map(\.imageId) == [1, 2])
        #expect(detector.calls == 1)
    }

    @Test func factsArchivedUsesProxyAndSkipsDetector() throws {
        let db = try makeFactsDB()
        try addImage(db, 1, exists: false, sha: "abc")
        try db.execute("UPDATE images SET availability = 'archived' WHERE id = 1", [])
        let detector = FakeDetector([dog()])
        #expect(try pool(db, detector).isEmpty)
        try writeFactsJPEG(try factsDir(db) + "/proxies/photos/abc.jpg")
        let p = try pool(db, detector)
        #expect(p.map(\.imageId) == [1])
        #expect(detector.calls == 0)
    }

    @Test func factsAlbumWithoutRunRaises() throws {
        let db = try makeFactsDB()
        try db.execute("UPDATE albums SET run_id = NULL", [])
        #expect(throws: AilbumError.invalid("У альбома нет анализа")) { try pool(db) }
    }
}
