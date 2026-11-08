import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private let integrationRun = "r"
private let integrationAlbum = 1
private let integrationUnselected: Set<Int> = [2, 10]
private let integrationClusters: [Int: Int] = [1: 10, 2: 10, 9: 11, 10: 11]
// Face boxes as fractions (x, y, w, h); image 1 has a face on the spine line.
private let integrationFaces: [Int: [(Double, Double, Double, Double)]] = [
    1: [(0.45, 0.30, 0.10, 0.18)],
    3: [(0.05, 0.40, 0.10, 0.16)],
    4: [(0.82, 0.20, 0.10, 0.16)],
    5: [(0.40, 0.55, 0.12, 0.18), (0.60, 0.50, 0.12, 0.18)],
    9: [(0.42, 0.25, 0.14, 0.12)],
    11: [(0.70, 0.60, 0.10, 0.15)],
    12: [(0.10, 0.10, 0.10, 0.16)],
    14: [(0.48, 0.40, 0.10, 0.15)],
]

private final class DownAssistant: LayoutAssisting, @unchecked Sendable {
    func connect() throws -> Bool { false }
    func choose(
        _ variants: [SpreadDraft], paths: [Int: String], orientation: String, storyTitle: String, wish: String
    ) throws -> AssistantChoice? { nil }
}

private final class ReplyAssistant: LayoutAssisting, @unchecked Sendable {
    func connect() throws -> Bool { true }
    func choose(
        _ variants: [SpreadDraft], paths: [Int: String], orientation: String, storyTitle: String, wish: String
    ) throws -> AssistantChoice? { AssistantChoice(index: 1, reason: "ритм") }
}

private func resetIntegration() {
    LayoutService.detectorFactory = nil
    LayoutService.assistantFactory = nil
    Editing.poolOverride = nil
    Editing.variantsOverride = nil
}

private func writeIntegrationJPEG(_ path: String, width: Int, height: Int, shade: Int) {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: CGFloat(shade % 255) / 255, green: 90 / 255, blue: 140 / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

/// Builds the 16-photo, 2-story synthetic library and installs the "assistant is down" fake.
private func buildIntegrationLibrary() throws -> (root: String, database: String) {
    LayoutService.assistantFactory = { _, _ in DownAssistant() }
    let root = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-li-\(UUID().uuidString)"
    let source = root + "/photos"
    try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
    var records: [PhotoRecord] = []
    var metadata: [ImageMetadata] = []
    for n in 1...16 {
        let (w, h) = n % 3 != 0 ? (600, 400) : (400, 600)
        let path = source + "/\(n).jpg"
        writeIntegrationJPEG(path, width: w, height: h, shade: n * 13)
        let story = n <= 8 ? 1 : 2
        let faces = (integrationFaces[n] ?? []).enumerated().map { i, f in
            FaceRecord(
                faceId: "f\(n)_\(i)",
                bbox: SIMD4(
                    Int((f.0 * Double(w)).rounded(.toNearestOrEven)), Int((f.1 * Double(h)).rounded(.toNearestOrEven)),
                    Int((f.2 * Double(w)).rounded(.toNearestOrEven)), Int((f.3 * Double(h)).rounded(.toNearestOrEven))),
                confidence: 0.9)
        }
        let meta = try Metadata.collect(path: path, source: source)
        records.append(
            PhotoRecord(
                photoId: "p\(n)", path: meta.path, width: w, height: h,
                takenAt: "2024-01-0\(story)T10:" + (n < 10 ? "0\(n)" : "\(n)") + ":00",
                sharpness: 100, exposure: 1, quality: 0.8, isBlurry: false,
                similarCluster: integrationClusters[n], storyId: story,
                selected: !integrationUnselected.contains(n), faces: faces))
        metadata.append(meta)
    }
    let stories = [(1, "Ужин"), (2, "Прогулка")].map { sid, title in
        StoryRecord(
            storyId: sid, title: title,
            photoIds: records.filter { $0.storyId == sid }.map(\.photoId),
            startedAt: "2024-01-0\(sid)T10:00:00", endedAt: "2024-01-0\(sid)T11:00:00",
            representativePhotoId: "p\(sid * 8 - 7)")
    }
    let manifest: JSONValue = [
        "run_id": .string(integrationRun), "started_at": "t", "generated_at": "t", "face_backend": "x",
        "config": ["lmstudio_url": "http://x/v1", "lmstudio_model": "m1"], "summary": [:],
    ]
    let database = root + "/a.sqlite"
    _ = try AnalysisStore.save(
        database: database, source: source, output: root + "/o", manifest: manifest, records: records,
        people: [], metadata: metadata, faceSimilarity: 0.8, stories: stories)
    let db = try Database.open(path: database)
    try db.execute(
        "INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at) VALUES (1, 'u1', 'А', ?, 't', 't')",
        [.text(integrationRun)])
    for (position, record) in records.enumerated() where record.selected {
        try db.execute(
            "INSERT INTO album_photos VALUES (?, ?, ?, 't')",
            [.integer(integrationAlbum), .integer(position + 1), .integer(position + 1)])
    }
    return (root, database)
}

private func integrationParams(_ spreads: Int = 4, _ low: Int = 3, _ high: Int = 4) -> LayoutParams {
    LayoutParams(orientation: "vertical", spreadCount: spreads, minPhotos: low, maxPhotos: high)
}

private func placedCells(_ layout: JSONValue) -> [(spread: JSONValue, cell: JSONValue)] {
    var out: [(JSONValue, JSONValue)] = []
    for spread in layout["spreads"]?.arrayValue ?? [] {
        for cell in spread["cells"]?.arrayValue ?? [] where cell["placement"]?["image_id"]?.intValue != nil {
            out.append((spread, cell))
        }
    }
    return out
}

private func integrationImageIds(_ layout: JSONValue) -> [Int] {
    placedCells(layout).compactMap { $0.cell["placement"]?["image_id"]?.intValue }
}

private func firstSpreadMap(_ layout: JSONValue) -> [Int: Int] {
    var map: [Int: Int] = [:]
    for cell in layout["spreads"]?.arrayValue?.first?["cells"]?.arrayValue ?? [] {
        if let i = cell["index"]?.intValue, let id = cell["placement"]?["image_id"]?.intValue { map[i] = id }
    }
    return map
}

private func get(_ database: String) throws -> JSONValue? {
    try LayoutStore.loadLayout(Database.open(path: database), albumId: integrationAlbum)
}

extension LayoutSeamSuites {
@Suite(.serialized) struct LayoutIntegrationTests {
    @Test func integrationFullFlowOnSyntheticLibrary() throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        let generated = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(), modelsDir: nil)
        let layout = try #require(try get(lib.database))
        #expect(layout["id"] == generated["id"])
        #expect(layout["stale"]?.boolValue == false)
        #expect(layout["spreads"]?.arrayValue?.count == 4)
        let ids = integrationImageIds(layout)
        #expect(ids.count == Set(ids).count)
        #expect(layout["assistant_model"] == .null || layout["assistant_model"] == nil)
        let warnings = (layout["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(warnings.contains { $0.contains("AI-редактор") })
        #expect(warnings.contains { $0.contains("Модель детектора") })
        let spreads = layout["spreads"]?.arrayValue ?? []
        #expect(Set(spreads.flatMap { ($0["story_ids"]?.arrayValue ?? []).compactMap(\.intValue) }) == [1, 2])
        let titleSet = Set(spreads.compactMap { $0["story_title"]?.stringValue })
        #expect(titleSet.isSubset(of: ["Ужин", "Прогулка"]))

        let spread = spreads[0]
        let spreadId = try #require(spread["id"]?.intValue)
        let before = firstSpreadMap(layout)

        // swap_cells exchanges two photos
        let swapped = try Editing.swapCells(database: lib.database, spreadId: spreadId, cellA: 0, cellB: 1)
        let after = firstSpreadMap(swapped)
        #expect(after[0] == before[1] && after[1] == before[0])

        // set_photo with an image used elsewhere swaps; each image stays used once
        let last = try #require(layout["spreads"]?.arrayValue?.last)
        let other = try #require(last["cells"]?.arrayValue?.first?["placement"]?["image_id"]?.intValue)
        let changed = try Editing.setPhoto(database: lib.database, spreadId: spreadId, cellIndex: 0, imageId: other)
        #expect(changed["spreads"]?.arrayValue?[0]["cells"]?.arrayValue?[0]["placement"]?["image_id"]?.intValue == other)
        let changedIds = integrationImageIds(changed)
        #expect(changedIds.count == Set(changedIds).count)
        #expect(changedIds.count == ids.count)

        // set_crop keeps the window and returns the contract
        let cell = try #require(changed["spreads"]?.arrayValue?[0]["cells"]?.arrayValue?[0])
        var crop = try #require(cell["placement"]?["crop"]?.objectValue)
        let cw = try #require(crop["w"]?.doubleValue)
        let cx = try #require(crop["x"]?.doubleValue)
        crop["x"] = .double(min(1.0 - cw, cx + 0.0))
        let cropped = try Editing.setCrop(
            database: lib.database, spreadId: spreadId, cellIndex: 0, crop: .object(crop))
        let croppedW = try #require(
            cropped["spreads"]?.arrayValue?[0]["cells"]?.arrayValue?[0]["placement"]?["crop"]?["w"]?.doubleValue)
        #expect(abs(croppedW - cw) < 1e-6)

        // set_template with another photo count is rejected, same count is accepted
        let count = spread["cells"]?.arrayValue?.count ?? 0
        let templates = try Templates.templatesFor("vertical", photoCount: count)
        let current = cropped["spreads"]?.arrayValue?[0]["template_id"]?.stringValue
        if let target = templates.map(\.id).first(where: { $0 != current }) {
            let retemplated = try Editing.setTemplate(database: lib.database, spreadId: spreadId, templateId: target)
            #expect(retemplated["spreads"]?.arrayValue?[0]["template_id"]?.stringValue == target)
        }
        let wrong = try Templates.templatesFor("vertical", photoCount: count + 1)
        #expect(throws: AilbumError.self) {
            try Editing.setTemplate(database: lib.database, spreadId: spreadId, templateId: wrong[0].id)
        }

        #expect(try get(lib.database)?["stale"]?.boolValue == false)

        // a selection change marks the layout stale
        try Database.open(path: lib.database).execute(
            "DELETE FROM album_photos WHERE album_id = ? AND image_id = 3", [.integer(integrationAlbum)])
        #expect(try get(lib.database)?["stale"]?.boolValue == true)
    }

    @Test(arguments: [2, 3, 4, 5]) func integrationSpreadCountExactAndImagesUnique(spreads: Int) throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        let layout = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(spreads, 2, 4),
            modelsDir: nil)
        let list = layout["spreads"]?.arrayValue ?? []
        #expect(list.count == spreads)
        #expect(list.compactMap { $0["position"]?.intValue } == Array(1...spreads))
        let ids = integrationImageIds(layout)
        let unplaced = (layout["unplaced"]?.arrayValue ?? []).compactMap { $0["image_id"]?.intValue }
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids).isDisjoint(with: unplaced))
    }

    @Test func integrationSimilarClusterUsesOneMember() throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        let layout = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(4, 3, 4), modelsDir: nil)
        let ids = Set(integrationImageIds(layout))
            .union((layout["unplaced"]?.arrayValue ?? []).compactMap { $0["image_id"]?.intValue })
        #expect(ids.intersection([1, 2]).count <= 1)
        #expect(ids.intersection([9, 10]).count <= 1)
    }

    @Test func integrationEveryPlacedFaceUncutOnSyntheticFaces() throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        let layout = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(), modelsDir: nil)
        let pool = Dictionary(
            uniqueKeysWithValues: try Facts.loadPool(
                Database.open(path: lib.database), albumId: integrationAlbum, detector: nil, progress: nil
            ).map { ($0.imageId, $0) })
        var checked = 0
        for (spread, cell) in placedCells(layout) {
            let placement = try #require(cell["placement"])
            let crop = try #require(placement["crop"])
            let imageId = try #require(placement["image_id"]?.intValue)
            let cx = try #require(crop["x"]?.doubleValue), cy = try #require(crop["y"]?.doubleValue)
            let cw = try #require(crop["w"]?.doubleValue), ch = try #require(crop["h"]?.doubleValue)
            for region in try #require(pool[imageId]).regions where region.hard {
                checked += 1
                let box = region.bbox
                let insideW = min(box.x + box.w, cx + cw) - max(box.x, cx)
                let insideH = min(box.y + box.h, cy + ch) - max(box.y, cy)
                let cover = max(insideW, 0) * max(insideH, 0) / (box.w * box.h)
                #expect(cover >= 0.98, "spread \(spread["id"]?.intValue ?? -1) cell \(cell["index"]?.intValue ?? -1) image \(imageId)")
            }
            let warnings = (placement["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
            #expect(!warnings.contains("face_cut"))
            #expect(!warnings.contains("face_on_spine"))
        }
        #expect(checked > 0)
    }

    @Test func integrationGenerationIsDeterministic() throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        let first = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(), modelsDir: nil)
        let second = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(), modelsDir: nil)
        func strip(_ layout: JSONValue) -> [[String]] {
            (layout["spreads"]?.arrayValue ?? []).map { s in
                (s["cells"]?.arrayValue ?? []).map { c in
                    "\(c["index"]?.intValue ?? -1):\(c["placement"]?["image_id"]?.intValue.map(String.init) ?? "nil")"
                }
            }
        }
        #expect(strip(first) == strip(second))
        #expect(
            (first["spreads"]?.arrayValue ?? []).map { $0["template_id"]?.stringValue }
                == (second["spreads"]?.arrayValue ?? []).map { $0["template_id"]?.stringValue })
    }

    @Test func integrationAssistantReplyIsRecorded() throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        LayoutService.assistantFactory = { _, _ in ReplyAssistant() }
        let layout = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(), modelsDir: nil)
        #expect(layout["assistant_model"]?.stringValue == "m1")
        let ids = integrationImageIds(layout)
        #expect(ids.count == Set(ids).count)
        for spread in layout["spreads"]?.arrayValue ?? [] {
            let reason = spread["assistant_reason"]?.stringValue
            #expect(reason == nil || reason == "ритм")
        }
    }

    // Python skips unless a YOLOX file exists; here the CoreML detector must be installed.
    @Test(.enabled(if: ModelStore.available("yolox"))) func integrationRealDetectorModelWhenAvailable() throws {
        resetIntegration()
        defer { resetIntegration() }
        let lib = try buildIntegrationLibrary()
        let models = lib.root + "/models"
        try FileManager.default.createDirectory(atPath: models + "/yolox.mlpackage", withIntermediateDirectories: true)
        let layout = try LayoutService.generate(
            database: lib.database, albumId: integrationAlbum, params: integrationParams(), modelsDir: models)
        let warnings = (layout["warnings"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(!warnings.contains { $0.contains("Модель детектора") })
        #expect(layout["spreads"]?.arrayValue?.count == 4)
        let rows = try Database.open(path: lib.database).query("SELECT COUNT(*) AS n FROM image_object_scans", [])
        if case .integer(let n)? = rows.first?["n"] { #expect(n > 0) } else { Issue.record("no scan count") }
        _ = try JSONEncoder().encode(layout)
    }
}
}
