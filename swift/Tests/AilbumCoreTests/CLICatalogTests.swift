import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AilbumCore

private final class Lines: @unchecked Sendable {
    var items: [String] = []
    var text: String { items.joined(separator: "\n") }
}

private func call(_ args: [String]) throws -> (code: Int32?, out: String) {
    let lines = Lines()
    let code = try CLICatalog.run(args, out: { lines.items.append($0) })
    return (code, lines.text)
}

private func tmpDir() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func writeJPEG(_ path: String, red: CGFloat = 80) throws {
    let ctx = CGContext(data: nil, width: 240, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: red / 255, green: 120 / 255, blue: 160 / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

/// Swappable producer: fake `Pipeline.analyzeLibrary` by default, the real one with SUPERLITE_REAL=1.
private func installAnalyze() {
    if ProcessInfo.processInfo.environment["SUPERLITE_REAL"] == "1" {
        CLICatalog.analyzeOverride = nil
        return
    }
    CLICatalog.analyzeOverride = { _, _, _, _, _, database in
        let c = try Database.open(path: database ?? "")
        try c.execute("INSERT INTO analysis_runs VALUES ('r9','s','o','t','t','classic','{}','{}','completed')", [])
        return ["run_id": "r9", "summary": ["photos": 0]]
    }
}

private struct Env {
    let dir: String, source: String, image: String, database: String
}

private func makeEnv() throws -> Env {
    let dir = try tmpDir()
    let source = dir + "/photos"
    try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
    let image = source + "/portrait.jpg"
    try writeJPEG(image)
    return Env(dir: dir, source: source, image: image, database: dir + "/catalog.sqlite3")
}

@discardableResult
private func saveRun(_ env: Env, _ runId: String, _ embedding: [Float], _ bbox: SIMD4<Int>) throws -> Int {
    let face = FaceRecord(
        faceId: "\(runId)-face", bbox: bbox, confidence: 0.95, personCluster: 1, embedding: embedding,
        eyes: EyeStateRecord(left: "open", right: "closed", leftOpenProbability: 0.91,
                             rightOpenProbability: 0.12, bothOpen: false),
        expression: ExpressionRecord(label: "happy", confidence: 0.84, smileProbability: 0.84,
                                     scores: ["happy": 0.84, "neutral": 0.16]))
    let photo = PhotoRecord(photoId: "\(runId)-photo", path: Catalog.resolve(env.image), width: 240, height: 180,
                            takenAt: nil, sharpness: 100, exposure: 1, quality: 1, isBlurry: false,
                            selected: true, faces: [face])
    let person = PersonRecord(clusterId: 1, faceIds: [face.faceId], photoIds: [photo.photoId],
                              embeddingModel: "test-model", centroid: embedding)
    let manifest: JSONValue = ["run_id": .string(runId), "started_at": "2026-08-07T10:00:00+00:00",
                               "generated_at": "2026-08-07T10:00:01+00:00", "face_backend": "test",
                               "config": [:], "summary": ["faces": 1, "people_groups": 1]]
    _ = try AnalysisStore.save(
        database: env.database, source: env.source, output: env.source + "/output", manifest: manifest,
        records: [photo], people: [person], metadata: [try Metadata.collect(path: env.image, source: env.source)],
        faceSimilarity: 0.8, stories: nil)
    let db = try Database.open(path: env.database)
    let rows = try db.query("SELECT person_id FROM faces WHERE face_id = ?", [.text(face.faceId)])
    guard case .integer(let id)? = rows.first?["person_id"] else { return 0 }
    return Int(id)
}

@Suite(.serialized) struct CLICatalogTests {
    @Test func testAnalyzeAttachesAlbum() throws {
        installAnalyze()
        defer { CLICatalog.analyzeOverride = nil }
        let dir = try tmpDir()
        let db = dir + "/db.sqlite3"
        let c = try Database.open(path: db)
        _ = try Albums.create(c, title: "Турция 2026", sources: ["/p"], runId: nil, targetCount: 5)
        let source = dir + "/new"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try writeJPEG(source + "/a.jpg")
        let r = try call(["analyze", source, "-o", dir + "/out", "--database", db, "--quiet"])
        #expect(r.code == 0)
        #expect(r.out.contains("Альбом: 2"))
        #expect(r.out.contains("База данных: \(Catalog.resolve(db))"))
    }

    @Test func testAnalyzeOptionsAndDefaults() throws {
        let seen = Lines()
        CLICatalog.analyzeOverride = { source, output, config, recursive, progress, database in
            let geo: String = config.photoGeometricSimilarity.map { String($0) } ?? "nil"
            let parts: [String] = [source, output, String(recursive), String(progress == nil), database ?? "",
                                   geo, String(config.featureCache), config.semanticBackend, String(config.storyGapMinutes)]
            seen.items = [parts.joined(separator: "|")]
            let c = try Database.open(path: database ?? "")
            try c.execute("INSERT INTO analysis_runs VALUES ('r1','s','o','t','t','classic','{}','{}','completed')", [])
            return ["run_id": "r1", "summary": ["photos": 0]]
        }
        defer { CLICatalog.analyzeOverride = nil }
        let dir = try tmpDir()
        let db = dir + "/d.sqlite3"
        _ = try call(["analyze", "/src", "--database", db, "--no-recursive", "--no-geometric-similarity",
                      "--no-feature-cache", "--semantic-backend=off", "--story-gap-minutes", "5"])
        #expect(seen.items == ["/src|output|false|false|\(db)|nil|false|off|5"])
        #expect(throws: AilbumError.self) { _ = try call(["analyze", "/src", "--face-backend", "bogus", "--database", db]) }
    }

    @Test func testIndexCommand() throws {
        let env = try makeEnv()
        let r = try call(["index", env.source, "--database", env.database])
        #expect(r.code == 0)
        #expect(r.out.contains("[1/1] portrait.jpg"))
        #expect(r.out.contains("База данных: \(Catalog.resolve(env.database))"))
        let quiet = try call(["index", env.source, "--database", env.database, "--quiet"])
        #expect(!quiet.out.contains("[1/1]"))
    }

    @Test func testDbStatsListShow() throws {
        let env = try makeEnv()
        _ = try call(["index", env.source, "--database", env.database, "--quiet"])
        let stats = try call(["db", "stats", "--database", env.database])
        #expect(stats.code == 0)
        #expect(stats.out.contains("\"images\": 1"))
        let list = try call(["db", "list", "--database", env.database])
        let rows = list.out.split(separator: "\n").map(String.init)
        #expect(rows[0] == "ID\tДата съёмки\tРазмер\tКамера\tПуть")
        #expect(rows[1] == "1\t-\t240x180\t-\t\(Catalog.resolve(env.image))")
        #expect(try call(["db", "list", "--json", "--limit", "1", "--database", env.database]).out.contains("\"availability\": \"present\""))
        #expect(try call(["db", "show", "1", "--database", env.database]).out.contains("\"id\": 1"))
        #expect(try call(["db", "usage", "--database", env.database]).code == nil)
    }

    @Test func testPeopleCommands() throws {
        let env = try makeEnv()
        let one = try saveRun(env, "run-1", [1, 0], SIMD4(10, 10, 60, 60))
        let two = try saveRun(env, "run-2", [0, 1], SIMD4(120, 30, 60, 60))
        let list = try call(["people", "list", "--database", env.database])
        let rows = list.out.split(separator: "\n").map(String.init)
        #expect(rows[0] == "ID\tИмя\tЛица\tФото\tМодель")
        #expect(rows[1] == "\(one)\t-\t1\t1\ttest-model")
        #expect(try call(["people", "list", "--json", "--database", env.database]).out.contains("\"embedding_model\": \"test-model\""))
        #expect(try call(["people", "show", "\(one)", "--database", env.database]).out.contains("\"faces\""))
        #expect(try call(["people", "name", "\(one)", "Алиса", "--database", env.database]).out.contains("Алиса"))
        let sheet = env.dir + "/sheet.jpg"
        let composed = try call(["people", "compose", "\(one)", "--output", sheet, "--face-size", "64", "--columns", "2", "--database", env.database])
        #expect(composed.code == 0)
        #expect(FileManager.default.fileExists(atPath: sheet))
        let merged = try call(["people", "merge", "\(one)", "\(two)", "--database", env.database])
        #expect(merged.out.contains("\"face_count\": 2"))
    }

    @Test func testModelsCommand() throws {
        let r = try call(["models"])
        #expect(r.code == 0)
        let rows = r.out.split(separator: "\n").map(String.init)
        #expect(rows.count == 6)
        #expect(rows[0] == "yunet\t\(ModelStore.available("yunet") ? "доступна" : "отсутствует")")
    }

    @Test func testCompareCommand() throws {
        let dir = try tmpDir()
        try writeJPEG(dir + "/a.jpg", red: 80)
        try writeJPEG(dir + "/b.jpg", red: 90)
        let r = try call(["compare", dir + "/a.jpg", dir + "/b.jpg", "--max-image-side", "200"])
        #expect(r.code == 0)
        #expect(r.out.contains("\"hash_color\": {"))
        #expect(r.out.hasPrefix("{\n  \""))
    }

    @Test func testEvaluateCommand() throws {
        let dir = try tmpDir()
        try "## A\na.jpg\n".write(toFile: dir + "/s.md", atomically: true, encoding: .utf8)
        #expect(throws: AilbumError.invalid("В базе нет запусков анализа")) {
            _ = try call(["evaluate", dir + "/s.md", "--database", dir + "/a.sqlite3"])
        }
    }

    @Test func testForeignCommandsReturnNil() throws {
        #expect(try call(["album", "list"]).code == nil)
        #expect(try call(["index-x"]).code == nil)
        #expect(try call([]).code == nil)
    }
}
