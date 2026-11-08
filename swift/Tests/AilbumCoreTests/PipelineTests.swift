import Foundation
import ImageIO
import SQLite3
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private func detailedImage() -> RGBImage {
    let w = 320, h = 320
    var px = [UInt8](repeating: 0, count: w * h * 3)
    for x in stride(from: 20, to: 300, by: 20) {
        for y in 10...310 where y < h {
            for dx in -1...1 {
                let i = (y * w + x + dx) * 3
                px[i] = 255; px[i + 1] = 200; px[i + 2] = 20
            }
        }
    }
    return RGBImage(width: w, height: h, pixels: px)
}

private func blurred(_ image: RGBImage) -> RGBImage {
    let r = 4, sigma = 2.0
    var kernel = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
    let total = kernel.reduce(0, +)
    kernel = kernel.map { $0 / total }
    let w = image.width, h = image.height
    func pass(_ src: [Double], horizontal: Bool) -> [Double] {
        var out = src
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            var acc = 0.0
            for k in -r...r {
                var xx = horizontal ? x + k : x, yy = horizontal ? y : y + k
                xx = min(max(xx, 0), w - 1); yy = min(max(yy, 0), h - 1)
                acc += src[(yy * w + xx) * 3 + c] * kernel[k + r]
            }
            out[(y * w + x) * 3 + c] = acc
        } } }
        return out
    }
    let result = pass(pass(image.pixels.map(Double.init), horizontal: true), horizontal: false)
    return RGBImage(width: w, height: h, pixels: result.map { UInt8(min(max($0.rounded(), 0), 255)) })
}

private func writeJPEG(_ image: RGBImage, to url: URL) throws {
    let provider = CGDataProvider(data: Data(image.pixels) as CFData)!
    let cg = CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24,
        bytesPerRow: image.width * 3, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func pipelineConfig(_ tmp: URL) -> PipelineConfig {
    var c = PipelineConfig()
    c.sharpnessThreshold = 0
    c.photoHashDistance = 16
    c.photoHistSimilarity = 0.5
    c.faceBackend = "off"
    c.semanticBackend = "off"
    c.storyNamingBackend = "rules"
    c.modelsDir = tmp.appendingPathComponent("models")
    return c
}

private func makePair(_ source: URL) throws {
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let detailed = detailedImage()
    try writeJPEG(detailed, to: source.appendingPathComponent("a.jpg"))
    try writeJPEG(blurred(detailed), to: source.appendingPathComponent("b.jpg"))
}

private func runPair(_ tmp: URL, database: String?) throws -> JSONValue {
    let source = tmp.appendingPathComponent("photos")
    try makePair(source)
    return try Pipeline.analyzeLibrary(
        source: source.path, output: tmp.appendingPathComponent("result").path,
        config: pipelineConfig(tmp), recursive: true, progress: nil, database: database)
}

private func count(_ db: String, _ sql: String) throws -> Int {
    let d = try Database.open(path: db)
    guard case .integer(let n)? = try d.query(sql, []).first?.values.first else { return -1 }
    return Int(n)
}

@Suite(.serialized) struct PipelineTests {
    @Test func pipelineWritesManifestAndSelectsBestOfDuplicates() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("photos")
        let output = tmp.appendingPathComponent("result")
        let db = tmp.appendingPathComponent("catalog.sqlite3").path
        try makePair(source)
        var progress: [String] = []
        let manifest = try Pipeline.analyzeLibrary(
            source: source.path, output: output.path, config: pipelineConfig(tmp), recursive: true,
            progress: { progress.append($0) }, database: db)

        #expect(manifest["summary"]?["photos"] == .int(2))
        #expect(manifest["summary"]?["selected"] == .int(1))
        #expect(progress.contains { $0.hasPrefix("Этап: Анализ фотографий|") })
        #expect(progress.contains { $0.hasPrefix("Этап: Поиск похожих кадров|") })
        #expect(progress.contains { $0.hasPrefix("Этап: Сохранение|") })
        #expect(progress.contains("[1/2] a.jpg"))
        #expect(manifest["photos"]?[0]?["selected"] == .bool(true))
        #expect(manifest["photos"]?[1]?["selected"] == .bool(false))

        let csv = try String(contentsOf: output.appendingPathComponent("selection.csv"), encoding: .utf8)
        #expect(csv.hasPrefix(
            "photo_id,path,sharpness,exposure,quality,aesthetic_score,composition_score,rule_of_thirds,"
            + "frame_occupancy,negative_space,crop_risk,color_balance,color_harmony,scene_tags,object_tags,"
            + "blurry,similar_cluster,story_id,faces,selected,error\r\n"))
        let onDisk = try JSONValue.parse(
            String(contentsOf: output.appendingPathComponent("analysis.json"), encoding: .utf8))
        #expect(onDisk["schema_version"] == .int(6))
        #expect(onDisk["summary"]?["stories"] == .int(1))
        #expect(onDisk["story_groups"]?[0]?["photo_ids"] == ["photo-00001", "photo-00002"])
        #expect(onDisk["photos"]?[0]?["story_id"] == .int(1))
        #expect(onDisk["photos"]?[0]?["composition"]?["rule_of_thirds"] != .null)
        #expect(onDisk["photos"]?[0]?["color"]?["harmony"] != .null)
        #expect(try count(db, "SELECT COUNT(*) FROM images") == 2)
        #expect(try count(db, "SELECT COUNT(*) FROM analysis_runs") == 1)
        #expect(try count(db, "SELECT COUNT(*) FROM photo_analysis") == 2)
        #expect(try count(db, "SELECT COUNT(*) FROM stories") == 1)
    }

    @Test func pipelineReusesFeatureCacheByContentHash() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var px = [UInt8](repeating: 0, count: 200 * 160 * 3)
        for y in 0..<160 { for x in 0..<200 where (x - 100) * (x - 100) + (y - 80) * (y - 80) <= 45 * 45 {
            let i = (y * 200 + x) * 3
            px[i] = 240; px[i + 1] = 180; px[i + 2] = 20
        } }
        try writeJPEG(RGBImage(width: 200, height: 160, pixels: px), to: source.appendingPathComponent("sample.jpg"))
        var config = pipelineConfig(tmp)
        config.sharpnessThreshold = 100
        config.featureCacheDir = tmp.appendingPathComponent("feature-cache")
        let first = try Pipeline.analyzeLibrary(
            source: source.path, output: tmp.appendingPathComponent("first").path, config: config,
            recursive: true, progress: nil, database: nil)
        let second = try Pipeline.analyzeLibrary(
            source: source.path, output: tmp.appendingPathComponent("second").path, config: config,
            recursive: true, progress: nil, database: nil)
        #expect(first["feature_cache"]?["writes"] == .int(1))
        #expect(first["feature_cache"]?["hits"] == .int(0))
        #expect(second["feature_cache"]?["hits"] == .int(1))
        #expect(second["summary"]?["feature_cache_hits"] == .int(1))
        #expect(second["photos"] == first["photos"])
    }

    @Test func pipelineWithoutModelRecordsQuality() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let manifest = try runPair(tmp, database: tmp.appendingPathComponent("c.sqlite3").path)
        #expect(manifest["selection_model"] == "quality")
        #expect(manifest["photos"]?[0]?["selected"] == .bool(true))
        #expect(manifest["photos"]?[1]?["selected"] == .bool(false))
    }

    @Test func pipelineWithFakeModelPicksByScore() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var weights = [Double](repeating: 0, count: RankingFeatures.names.count)
        weights[0] = -1  // prefers lowest quality
        Pipeline.pairwiseOverride = (
            7, LogisticModel(weights: weights, bias: 0, mean: [Double](repeating: 0, count: weights.count),
                             std: [Double](repeating: 1, count: weights.count)))
        defer { Pipeline.pairwiseOverride = nil }
        let manifest = try runPair(tmp, database: tmp.appendingPathComponent("c.sqlite3").path)
        #expect(manifest["selection_model"] == "pairwise:7")
        #expect(manifest["photos"]?[0]?["selected"] == .bool(false))
        #expect(manifest["photos"]?[1]?["selected"] == .bool(true))
    }

    @Test func pipelineCorruptFileGivesErrorRecordAndContinues() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("photos")
        try makePair(source)
        try Data("not an image".utf8).write(to: source.appendingPathComponent("c.jpg"))
        let manifest = try Pipeline.analyzeLibrary(
            source: source.path, output: tmp.appendingPathComponent("result").path,
            config: pipelineConfig(tmp), recursive: true, progress: nil, database: nil)
        #expect(manifest["summary"]?["photos"] == .int(3))
        #expect(manifest["summary"]?["errors"] == .int(1))
        #expect(manifest["photos"]?[2]?["error"] != .null)
        #expect(manifest["photos"]?[2]?["width"] == .int(0))
        #expect(manifest["photos"]?[0]?["error"] == .null)
    }
}

@Suite(.serialized) struct PipelinePeopleSyncTests {
    @Test func syncPeopleCopiesDatabaseIdsBackIntoRecordsAndPeople() throws {
        let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-sync-\(UUID().uuidString)"
        let src = dir + "/src"
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dbPath = dir + "/c.sqlite3"
        let m = ImageMetadata(
            path: src + "/1.jpg", sourceRoot: src, relativePath: "1.jpg", fileName: "1.jpg", extension: ".jpg",
            fileSizeBytes: 10, modifiedAt: "2024-05-01T10:00:00", sha256: "s1", width: 40, height: 30,
            takenAt: "2024-05-01T10:00:00")
        var records = [PhotoRecord(
            photoId: "p1", path: m.path, width: 40, height: 30, takenAt: "2024-05-01T10:00:00",
            sharpness: 1, exposure: 0.5, quality: 0.5, isBlurry: false,
            faces: [
                FaceRecord(faceId: "f1", bbox: SIMD4(1, 2, 3, 4), confidence: 0.9, personCluster: 1,
                           embedding: [0.6, 0.8, 0]),
                FaceRecord(faceId: "f2", bbox: SIMD4(1, 2, 3, 4), confidence: 0.9, embedding: nil),
            ])]
        var people = [PersonRecord(
            clusterId: 1, faceIds: ["f1"], photoIds: ["p1"], embeddingModel: "sface", centroid: [0.6, 0.8, 0])]
        let runId = String(repeating: "b", count: 32)
        let manifest: JSONValue = [
            "run_id": .string(runId), "started_at": "2024-05-01T10:00:00+00:00",
            "generated_at": "2024-05-01T10:01:00+00:00", "face_backend": "dnn", "config": [:], "summary": [:],
        ]
        _ = try AnalysisStore.save(
            database: dbPath, source: src, output: dir + "/out", manifest: manifest, records: records,
            people: people, metadata: [m], faceSimilarity: 0.5, stories: [])
        #expect(records[0].faces[0].personId == nil)
        try Pipeline.syncPeople(database: dbPath, runId: runId, records: &records, people: &people)
        #expect(records[0].faces[0].personId != nil)
        #expect(records[0].faces[1].personId == nil)
        #expect(people[0].personId == records[0].faces[0].personId)
        #expect(people[0].publicId != nil)
    }
}
