import Foundation
import Testing
@testable import AilbumCore

private func makeDB() throws -> Database {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return try Database.open(path: dir + "/db.sqlite3")
}

private final class Seeder {
    let db: Database
    var nextImage = 1
    init(_ db: Database) { self.db = db }

    func image(_ sha: String? = nil) throws -> Int {
        let i = nextImage
        nextImage += 1
        try db.execute(
            "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
            + " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
            + " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            [.integer(i), .text("/p/\(i).jpg"), .text("/p"), .text("\(i).jpg"), .text("\(i).jpg"), .text(".jpg"),
             .integer(1), .text("t"), .text(sha ?? "sha\(i)"), .text("{}"), .text("{}"), .text("t")])
        return i
    }

    @discardableResult
    func album(_ n: Int, _ groups: Int, events: Bool = true, shas: [String]? = nil,
               qualityPick: Bool = false) throws -> String {
        let run = "run\(n)"
        try db.execute("INSERT INTO analysis_runs VALUES (?,?,?,?,?,?,?,?,?)",
                       [.text(run), .text("/p"), .text("/o"), .text("t"), .text("t"), .text("classic"),
                        .text("{}"), .text("{}"), .text("completed")])
        try db.execute("INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                       [.integer(n), .text("pub\(n)"), .text("a\(n)"), .text(run), .text("t"), .text("t")])
        for g in 0..<groups {
            let a = try image(shas?[2 * g])
            let b = try image(shas?[2 * g + 1])
            for (imageId, q) in [(a, 0.9), (b, 0.5)] {
                try db.execute(
                    "INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure, quality,"
                    + " is_blurry, similar_cluster, selected) VALUES (?,?,?,?,?,?,0,?,0)",
                    [.text(run), .integer(imageId), .text("p\(imageId)"), .real(1), .real(1), .real(q), .integer(g + 1)])
                try db.execute(
                    "INSERT INTO faces (run_id, image_id, face_id, face_index, bbox_x, bbox_y,"
                    + " bbox_width, bbox_height, confidence, left_eye_state, right_eye_state)"
                    + " VALUES (?,?,?,?,0,0,5,5,0.9,?,?)",
                    [.text(run), .integer(imageId), .text("f\(imageId)"), .integer(0),
                     .text(imageId == b ? "open" : "closed"), .text("open")])
            }
            let pick = qualityPick ? a : b
            try db.execute("INSERT INTO album_photos VALUES (?,?,?,?)",
                           [.integer(n), .integer(pick), .integer(g), .text("t")])
            if events {
                try db.execute(
                    "INSERT INTO selection_events (album_id, run_id, image_id, action, source, created_at)"
                    + " VALUES (?,?,?,?,?,?)",
                    [.integer(n), .text(run), .integer(pick), .text("add"), .text("manual"), .text("t")])
            }
        }
        return run
    }
}

private func model(version: Int? = nil) -> LogisticModel {
    var m = LogisticModel.fit(x: [[0], [1], [2], [3]], y: [0, 0, 1, 1], l2: 1.0)
    m.featureVersion = version ?? RankingFeatures.version
    return m
}

@Suite struct RankingTrainTests {
    @Test func testTrainGroupPairsOnlyTouched() {
        let groups = [1: [1, 2], 2: [3, 4]]
        let events: [JSONValue] = [
            .object(["image_id": .int(2), "source": .string("manual"), "action": .string("add")]),
            .object(["image_id": .int(3), "source": .string("auto"), "action": .string("seed")]),
        ]
        let pairs = RankingLabels.groupPairs(events: events, final: [2, 3], groups: groups)
        #expect(pairs.count == 1 && pairs[0] == (2, 1))
    }

    @Test func testTrainReasonTexts() {
        #expect(RankingTrain.reason == "нужно не меньше 50 пар из 2 альбомов")
        #expect(RankingTrain.pointwiseReason == "нужно не меньше 2 альбомов с 5 ручными действиями")
    }

    @Test func testTrainStatusNotEnough() throws {
        let db = try makeDB()
        try Seeder(db).album(1, 3)
        let st = try RankingTrain.status(db)
        #expect(st["pairs"] == .int(3) && st["albums"] == .int(1))
        #expect(st["pairwise"] == .null && st["pointwise"] == .null)
        #expect(st["reason"] == .string("нужно не меньше 50 пар из 2 альбомов"))
        #expect(try RankingTrain.train(db)["pairwise"] == .null)
    }

    @Test func testTrainEyesOpenRankerBeatsQuality() throws {
        let db = try makeDB()
        let s = Seeder(db)
        try s.album(1, 30)
        try s.album(2, 30)
        let out = try RankingTrain.train(db)
        #expect(out["pairwise"]?["active"] == .bool(true))
        #expect(out["pairwise"]?["accuracy"] == .double(1.0))
        #expect(out["pairwise"]?["baseline"] == .double(0.0))
        let active = try #require(try RankingStore.activeModel(db, kind: "pairwise"))
        #expect(.int(active.id) == out["pairwise"]?["id"])
        let run = try s.album(3, 1, events: false)
        let vec = try RankingFeatures.fromRows(db, runId: run)
        let a = vec[s.nextImage - 2]!, b = vec[s.nextImage - 1]!
        let scores = active.model.score([a, b])
        #expect(scores[1] > scores[0])
        #expect(a[RankingFeatures.names.firstIndex(of: "quality")!] > 0.5)
    }

    @Test func testTrainNotActivatedWhenWorseThanBaseline() throws {
        let db = try makeDB()
        let s = Seeder(db)
        try s.album(1, 30)
        try s.album(2, 30, qualityPick: true)
        let p = try #require(try RankingTrain.evaluate(db)["pairwise"])
        let acc = try #require(p["accuracy"]?.doubleValue), base = try #require(p["baseline"]?.doubleValue)
        #expect(p["active"] == .bool(acc >= base))
        #expect(try RankingStore.activeModel(db, kind: "pairwise") == nil)
    }

    @Test func testTrainShaDuplicatesShareOneFold() throws {
        let db = try makeDB()
        let s = Seeder(db)
        let shas = (0..<60).map { "s\($0)" }
        try s.album(1, 30, shas: shas)
        try s.album(2, 30, shas: shas)
        let out = try RankingTrain.evaluate(db)
        #expect(out["pairwise"]?["accuracy"] == .null)
        #expect(out["pairwise"]?["active"] == .bool(false))
    }

    @Test func testTrainPointwiseNeedsFiveEvents() throws {
        let db = try makeDB()
        let s = Seeder(db)
        try s.album(1, 6)
        try s.album(2, 3)
        #expect(try RankingTrain.evaluate(db)["pointwise"] == .null)
        try s.album(3, 6)
        #expect(try RankingTrain.evaluate(db)["pointwise"]?["albums"] == .int(2))
    }

    @Test func testTrainStaleFeatureVersionIgnored() throws {
        let db = try makeDB()
        _ = try RankingStore.saveModel(db, kind: "pairwise", model: model(version: RankingFeatures.version + 1),
                                       metrics: .object([:]), active: true)
        #expect(try RankingStore.activeModel(db, kind: "pairwise") == nil)
        let good = model()
        _ = try RankingStore.saveModel(db, kind: "pairwise", model: good, metrics: .object([:]), active: true)
        #expect(try RankingStore.activeModel(db, kind: "pairwise") != nil)
        let newId = try RankingStore.saveModel(db, kind: "pairwise", model: good, metrics: .object([:]), active: true)
        #expect(try RankingStore.activeModel(db, kind: "pairwise")?.id == newId)
        let rows = try db.query("SELECT COUNT(*) AS n FROM ranking_models WHERE active = 1", [])
        #expect(rows[0]["n"] == .integer(1))
    }
}
