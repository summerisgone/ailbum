import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private final class FakeAssistant: LayoutAssisting, @unchecked Sendable {
    nonisolated(unsafe) static var instances: [FakeAssistant] = []
    nonisolated(unsafe) static var connected = true
    nonisolated(unsafe) static var choice: AssistantChoice? = AssistantChoice(index: 1, reason: "лучше")
    nonisolated(unsafe) static var raises = false
    let baseURL: String
    let model: String
    var chooseCalls = 0
    var titles: [String] = []
    var seen: [[SpreadDraft]] = []

    init(_ baseURL: String, _ model: String) {
        self.baseURL = baseURL
        self.model = model
        FakeAssistant.instances.append(self)
    }

    func connect() throws -> Bool { FakeAssistant.connected }

    func choose(
        _ variants: [SpreadDraft], paths: [Int: String], orientation: String, storyTitle: String, wish: String
    ) throws -> AssistantChoice? {
        chooseCalls += 1
        titles.append(storyTitle)
        seen.append(variants)
        if FakeAssistant.raises { throw AilbumError.invalid("down") }
        return FakeAssistant.choice
    }
}

private func resetFakes() {
    FakeAssistant.instances = []
    FakeAssistant.connected = true
    FakeAssistant.choice = AssistantChoice(index: 1, reason: "лучше")
    FakeAssistant.raises = false
    LayoutService.detectorFactory = nil
    LayoutService.assistantFactory = nil
}

private func writeServiceJPEG(_ path: String, width: Int, height: Int, shade: Int) {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: CGFloat(shade % 255) / 255, green: 80 / 255, blue: 120 / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

private let serviceTitles = [1: "Ужин", 2: "Прогулка"]

private struct ServiceEnv {
    let root: String
    let path: String
    let db: Database
}

/// Seeds an album with one analysed, selected photo per count (ordered by story).
private func seedService(_ perStory: [(Int?, Int)]) throws -> ServiceEnv {
    let root = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-ls-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root + "/photos", withIntermediateDirectories: true)
    let path = root + "/a.sqlite"
    let db = try Database.open(path: path)
    try db.execute(
        "INSERT INTO analysis_runs VALUES ('r','s','o','t','t','dnn',?,'{}','completed')",
        [.text("{\"lmstudio_url\": \"http://x/v1\", \"lmstudio_model\": \"m1\"}")])
    try db.execute(
        "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at)"
        + " VALUES (1, 'u1', 'А', 'r', 't', 't')", [])
    var n = 0
    for (story, count) in perStory {
        for _ in 0..<count {
            n += 1
            let landscape = n % 2 == 1
            let (w, h) = landscape ? (300, 200) : (200, 300)
            let file = root + "/photos/\(n).jpg"
            writeServiceJPEG(file, width: w, height: h, shade: n * 5)
            let day = story ?? 9
            let taken = "2024-01-0\(day)T10:" + (n < 10 ? "0\(n)" : "\(n)") + ":00"
            try db.execute(
                """
                INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
                file_size_bytes, modified_at, sha256, width, height, orientation, taken_at,
                exif_json, container_metadata_json, indexed_at)
                VALUES (?, ?, 's', ?, ?, '.jpg', 1, 't', ?, ?, ?, NULL, ?, '{}', '{}', 't')
                """,
                [.integer(n), .text(file), .text("\(n).jpg"), .text("\(n).jpg"), .text("sha\(n)"),
                 .integer(w), .integer(h), .text(taken)])
            try db.execute(
                """
                INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,
                aesthetic_score, is_blurry, similar_cluster, story_id, selected)
                VALUES ('r', ?, ?, 1, 1, 0.8, NULL, 0, NULL, ?, 1)
                """,
                [.integer(n), .text("p\(n)"), story.map { .integer($0) } ?? .null])
            try db.execute("INSERT INTO album_photos VALUES (1, ?, ?, 't')", [.integer(n), .integer(n)])
        }
    }
    for (story, _) in perStory {
        guard let story else { continue }
        try db.execute(
            "INSERT INTO stories (run_id, story_id, title, started_at, ended_at) VALUES ('r', ?, ?, ?, ?)",
            [.integer(story), .text(serviceTitles[story] ?? ""), .text("2024-01-0\(story)T10:00:00"),
             .text("2024-01-0\(story)T11:00:00")])
    }
    return ServiceEnv(root: root, path: path, db: db)
}

private func params(_ spreads: Int, _ minPhotos: Int, _ maxPhotos: Int, _ assistant: String = "auto")
    -> LayoutParams
{
    LayoutParams(
        orientation: "vertical", spreadCount: spreads, minPhotos: minPhotos, maxPhotos: maxPhotos,
        assistant: assistant)
}

private func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

private func placedIds(_ layout: JSONValue) -> [Int] {
    var ids: [Int] = []
    for spread in layout["spreads"]?.arrayValue ?? [] {
        for cell in spread["cells"]?.arrayValue ?? [] {
            if let id = cell["placement"]?["image_id"]?.intValue { ids.append(id) }
        }
    }
    return ids
}

@Suite(.serialized) enum LayoutSeamSuites {}

extension LayoutSeamSuites {
@Suite(.serialized) struct LayoutServiceTests {
    @Test func servicePreflightCountsUnitsNotPhotos() throws {
        resetFakes()
        let e = try seedService([(1, 3), (2, 1)])
        let result = try LayoutService.preflight(database: e.path, albumId: 1, params: params(2, 1, 6))
        #expect(result["pool_count"]?.intValue == 4)
        #expect(result["unit_count"]?.intValue == 4)
        #expect(result["story_count"]?.intValue == 2)
    }

    @Test func serviceMinMaxNeeded() throws {
        resetFakes()
        let e = try seedService([(1, 20), (2, 20)])
        let result = try LayoutService.preflight(database: e.path, albumId: 1, params: params(10, 3, 6))
        #expect(result["min_needed"]?.intValue == 30)
        #expect(result["max_used"]?.intValue == 60)
        #expect(result["errors"]?.arrayValue?.isEmpty == true)
        let titles = (result["allocation"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
        #expect(titles == ["Ужин", "Прогулка"])
    }

    @Test func servicePreflightZeroSpreadsError() throws {
        resetFakes()
        let e = try seedService([(1, 5)])
        let result = try LayoutService.preflight(database: e.path, albumId: 1, params: params(0, 3, 6))
        #expect(strings(result["errors"]) == ["Число разворотов должно быть не меньше 1"])
        #expect(result["allocation"]?.arrayValue?.isEmpty == true)
    }

    @Test func servicePreflightRangeErrors() throws {
        resetFakes()
        let e = try seedService([(1, 5)])
        var result = try LayoutService.preflight(database: e.path, albumId: 1, params: params(1, 5, 3))
        #expect(strings(result["errors"]).contains { $0.contains("больше максимума") })
        result = try LayoutService.preflight(database: e.path, albumId: 1, params: params(1, 0, 9))
        #expect(strings(result["errors"]).contains { $0.contains("от 1 до 8") })
    }

    @Test func servicePreflightFewerUnitsThanSpreads() throws {
        resetFakes()
        let e = try seedService([(1, 2)])
        let result = try LayoutService.preflight(database: e.path, albumId: 1, params: params(5, 1, 6))
        #expect(strings(result["errors"]) == ["Кадров меньше, чем разворотов"])
    }

    @Test func servicePreflightSkipsDetector() throws {
        resetFakes()
        nonisolated(unsafe) var opened = 0
        LayoutService.detectorFactory = { _ in opened += 1; return nil }
        defer { resetFakes() }
        let e = try seedService([(1, 5)])
        _ = try LayoutService.preflight(database: e.path, albumId: 1, params: params(1, 3, 6))
        #expect(opened == 0)
    }

    @Test func serviceGenerateInvalidParamsRaises() throws {
        resetFakes()
        let e = try seedService([(1, 5)])
        #expect(throws: AilbumError.invalid("Число разворотов должно быть не меньше 1")) {
            try LayoutService.generate(
                database: e.path, albumId: 1, params: params(0, 3, 6), modelsDir: nil, progress: nil)
        }
        #expect(try LayoutStore.loadLayout(e.db, albumId: 1) == nil)
    }

    @Test func serviceGenerateEmptySelectionRaises() throws {
        resetFakes()
        let e = try seedService([])
        #expect(throws: AilbumError.self) {
            try LayoutService.generate(
                database: e.path, albumId: 1, params: params(2, 3, 6), modelsDir: nil, progress: nil)
        }
    }

    @Test func serviceGenerateSpreadCountExact() throws {
        resetFakes()
        let e = try seedService([(1, 12), (2, 8)])
        nonisolated(unsafe) var events: [(String, String, Int?, Int?)] = []
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(5, 3, 6, "off"), modelsDir: nil
        ) { events.append(($0, $1, $2, $3)) }
        #expect(layout["spreads"]?.arrayValue?.count == 5)
        let labels = Set(events.map(\.0))
        #expect(labels.isSuperset(of: ["Анализ объектов", "Компоновка"]))
        #expect(events.first.map { $0.0 == "Анализ объектов" && $0.2 == 0 && $0.3 == nil } == true)
        #expect(events.last.map { $0.0 == "Компоновка" && $0.2 != nil && $0.2 == $0.3 } == true)
    }

    @Test func serviceGenerateRealSpreadCountExact() throws {
        resetFakes()
        let e = try seedService([(1, 12), (2, 8)])
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(5, 3, 6, "off"), modelsDir: nil, progress: nil)
        #expect(layout["spreads"]?.arrayValue?.count == 5)
    }

    @Test func serviceAssistantOffNeverConnects() throws {
        resetFakes()
        LayoutService.assistantFactory = { FakeAssistant($0, $1) }
        defer { resetFakes() }
        let e = try seedService([(1, 6)])
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(1, 3, 6, "off"), modelsDir: nil, progress: nil)
        #expect(FakeAssistant.instances.isEmpty)
        #expect(layout["assistant_model"] == .null)
        #expect(!strings(layout["warnings"]).contains(LayoutService.assistantWarning))
    }

    @Test func serviceAssistantUsesRunConfigAndChoice() throws {
        resetFakes()
        LayoutService.assistantFactory = { FakeAssistant($0, $1) }
        defer { resetFakes() }
        let e = try seedService([(1, 6), (2, 6)])
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(2, 3, 6, "auto"), modelsDir: nil, progress: nil)
        let bot = try #require(FakeAssistant.instances.first)
        #expect(bot.baseURL == "http://x/v1" && bot.model == "m1")
        #expect(layout["assistant_model"]?.stringValue == "m1")
        #expect(bot.titles == ["Ужин", "Прогулка"])
    }

    @Test func serviceAssistantChoiceKeepsReplacementAndReason() throws {
        resetFakes()
        LayoutService.assistantFactory = { FakeAssistant($0, $1) }
        defer { resetFakes() }
        let e = try seedService([(1, 6)])
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(1, 3, 6, "auto"), modelsDir: nil, progress: nil)
        let bot = try #require(FakeAssistant.instances.first)
        let variants = try #require(bot.seen.first)
        let saved = try #require(layout["spreads"]?[0])
        #expect(saved["template_id"]?.stringValue == variants[1].templateId)
        #expect(strings(saved["warnings"]) == variants[1].warnings)
        #expect(saved["story_ids"]?.arrayValue?.compactMap(\.intValue) == variants[1].storyIds)
        #expect(saved["story_ids"]?.arrayValue?.compactMap(\.intValue) == [1])
        #expect(saved["assistant_reason"]?.stringValue == "лучше")
    }

    @Test func serviceAssistantFailureKeepsEngineChoice() throws {
        resetFakes()
        LayoutService.assistantFactory = { FakeAssistant($0, $1) }
        defer { resetFakes() }
        let e = try seedService([(1, 6)])
        FakeAssistant.raises = true
        var layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(1, 3, 6, "auto"), modelsDir: nil, progress: nil)
        var variants = try #require(FakeAssistant.instances.last?.seen.first)
        #expect(layout["spreads"]?[0]?["template_id"]?.stringValue == variants[0].templateId)
        #expect(layout["spreads"]?[0]?["assistant_reason"] == .null)
        FakeAssistant.raises = false
        FakeAssistant.choice = AssistantChoice(index: 7, reason: "x")
        layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(1, 3, 6, "auto"), modelsDir: nil, progress: nil)
        variants = try #require(FakeAssistant.instances.last?.seen.first)
        #expect(layout["spreads"]?[0]?["template_id"]?.stringValue == variants[0].templateId)
        #expect(layout["spreads"]?[0]?["assistant_reason"] == .null)
    }

    @Test func serviceAssistantServerDownWarns() throws {
        resetFakes()
        LayoutService.assistantFactory = { FakeAssistant($0, $1) }
        defer { resetFakes() }
        let e = try seedService([(1, 6)])
        FakeAssistant.connected = false
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(1, 3, 6, "auto"), modelsDir: nil, progress: nil)
        #expect(strings(layout["warnings"]).contains(LayoutService.assistantWarning))
        #expect(layout["assistant_model"] == .null)
        #expect(FakeAssistant.instances.first?.chooseCalls == 0)
    }

    @Test func serviceNoDetectorModelWarns() throws {
        resetFakes()
        let e = try seedService([(1, 6)])
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(1, 3, 6, "off"), modelsDir: nil, progress: nil)
        #expect(strings(layout["warnings"]).contains(LayoutService.detectorWarning))
    }

    @Test func serviceUntimedGroupPhotosNotLost() throws {
        resetFakes()
        let e = try seedService([(1, 4), (nil, 2)])
        let layout = try LayoutService.generate(
            database: e.path, albumId: 1, params: params(2, 1, 6, "off"), modelsDir: nil, progress: nil)
        let unplaced = (layout["unplaced"]?.arrayValue ?? []).compactMap { $0["image_id"]?.intValue }
        #expect((placedIds(layout) + unplaced).sorted() == [1, 2, 3, 4, 5, 6])
    }

    @Test func serviceGenerateOnOrderedAlbumRaises() throws {
        resetFakes()
        let e = try seedService([(1, 5)])
        try e.db.execute("UPDATE albums SET status = 'ordered'", [])
        #expect(throws: AilbumError.self) {
            try LayoutService.generate(
                database: e.path, albumId: 1, params: params(1, 3, 6, "off"), modelsDir: nil, progress: nil)
        }
        #expect(try LayoutStore.loadLayout(e.db, albumId: 1) == nil)
    }

    @Test func serviceImagePathsUseProxyForArchived() throws {
        resetFakes()
        let e = try seedService([(1, 2)])
        try e.db.execute("UPDATE images SET availability = 'archived' WHERE id = 1", [])
        let proxy = Proxies.photoProxy(database: e.path, sha256: "sha1")
        try FileManager.default.createDirectory(
            atPath: (proxy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        writeServiceJPEG(proxy, width: 8, height: 8, shade: 0)
        let paths = try LayoutService.imagePaths(database: e.path, e.db, [1, 2])
        #expect(paths[1] == proxy)
        #expect(paths[2] != nil && paths[2] != proxy)
    }
}
}
