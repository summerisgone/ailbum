import Foundation
import Testing
@testable import AilbumCore

private func makeDB() throws -> Database {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let db = try Database.open(path: dir + "/c.sqlite3")
    try db.execute("DROP TABLE IF EXISTS faces", [])
    try db.execute("DROP TABLE IF EXISTS photo_analysis", [])
    try db.execute("""
        CREATE TABLE photo_analysis (run_id TEXT, image_id INTEGER, photo_id TEXT, sharpness REAL,
         exposure REAL, quality REAL, aesthetic_score REAL, composition_score REAL, rule_of_thirds REAL,
         crop_risk REAL, color_balance REAL, color_harmony REAL, is_blurry INTEGER, similar_cluster INTEGER,
         error TEXT)
        """, [])
    try db.execute("""
        CREATE TABLE faces (run_id TEXT, image_id INTEGER, left_eye_state TEXT, right_eye_state TEXT,
         smile_probability REAL, person_id INTEGER)
        """, [])
    return db
}

private func record(_ full: Bool) -> PhotoRecord {
    var rec = PhotoRecord(photoId: "p", path: "/p.jpg", width: 10, height: 10, takenAt: nil,
                          sharpness: 120, exposure: 0.8, quality: 0.7, isBlurry: false)
    if full {
        rec.composition = CompositionRecord(ruleOfThirds: 0.5, frameOccupancy: 0.4, negativeSpace: 0.3,
                                            cropRisk: 0.2, score: 0.6)
        rec.color = ColorRecord(balance: 0.9, harmony: 0.8, meanSaturation: 0.1)
        rec.semantics = SemanticRecord(aestheticScore: 0.75, model: "m")
        rec.faces = [
            FaceRecord(faceId: "f1", bbox: SIMD4(0, 0, 5, 5), confidence: 0.9, personId: 3,
                       eyes: EyeStateRecord(left: "closed", right: "open"),
                       expression: ExpressionRecord(label: "happy", confidence: 0.9, smileProbability: 0.6, scores: [:])),
            FaceRecord(faceId: "f2", bbox: SIMD4(0, 0, 5, 5), confidence: 0.9,
                       expression: ExpressionRecord(label: "n", confidence: 0.9, smileProbability: 0.2, scores: [:])),
        ]
    }
    return rec
}

private func opt(_ d: Double?) -> SQLValue { d.map { .real($0) } ?? .null }
private func optI(_ i: Int?) -> SQLValue { i.map { .integer($0) } ?? .null }
private func optS(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }

private func insert(_ db: Database, _ run: String, _ id: Int, _ rec: PhotoRecord, _ cluster: Int?) throws {
    let c = rec.composition, col = rec.color, s = rec.semantics
    try db.execute(
        "INSERT INTO photo_analysis VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
        [.text(run), .integer(id), .text(rec.photoId), .real(rec.sharpness), .real(rec.exposure),
         .real(rec.quality), opt(s?.aestheticScore), opt(c?.score), opt(c?.ruleOfThirds), opt(c?.cropRisk),
         opt(col?.balance), opt(col?.harmony), .integer(rec.isBlurry ? 1 : 0), optI(cluster)])
    for f in rec.faces {
        try db.execute("INSERT INTO faces VALUES (?,?,?,?,?,?)",
                       [.text(run), .integer(id), optS(f.eyes?.left), optS(f.eyes?.right),
                        opt(f.expression?.smileProbability), optI(f.personId)])
    }
}

@Suite struct RankingFeaturesTests {
    @Test func testPlanExamples() {
        #expect(RankingFeatures.names.count == 19)
        #expect(RankingFeatures.names[0] == "quality")
        #expect(RankingFeatures.version == 1)
        var r = record(false)
        r.quality = 0.5; r.sharpness = 100; r.exposure = 0.8
        #expect(RankingFeatures.fromRecord(r, groupSize: 3, groupRank: 1)
            == [0.5, 100, 0.8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1])
    }

    @Test func testMissingValuesZeroWithFlag() {
        func dict(_ v: [Double]) -> [String: Double] { Dictionary(uniqueKeysWithValues: zip(RankingFeatures.names, v)) }
        let v = dict(RankingFeatures.fromRecord(record(false), groupSize: 1, groupRank: 0))
        #expect(v["aesthetic_score"] == 0 && v["has_aesthetic"] == 0)
        #expect(v["composition_score"] == 0 && v["has_composition"] == 0)
        #expect(v["smile_max"] == 0 && v["has_smile"] == 0)
        let full = dict(RankingFeatures.fromRecord(record(true), groupSize: 2, groupRank: 1))
        #expect(full["has_aesthetic"] == 1 && full["closed_eyes_count"] == 1)
        #expect(full["smile_max"] == 0.6 && full["known_people_count"] == 1)
        #expect(full["face_count"] == 2 && full["group_size"] == 2 && full["group_rank"] == 1)
    }

    @Test func testFromRecordEqualsFromRows() throws {
        let db = try makeDB()
        let a = record(true)
        var b = record(false); b.quality = 0.9
        var c = record(true); c.quality = 0.1
        try insert(db, "r", 1, a, 5)
        try insert(db, "r", 2, b, 5)
        try insert(db, "r", 3, c, nil)
        let rows = try RankingFeatures.fromRows(db, runId: "r")
        #expect(rows[1] == RankingFeatures.fromRecord(a, groupSize: 2, groupRank: 1))
        #expect(rows[2] == RankingFeatures.fromRecord(b, groupSize: 2, groupRank: 0))
        #expect(rows[3] == RankingFeatures.fromRecord(c, groupSize: 1, groupRank: 0))
        #expect(rows[1]?.count == RankingFeatures.names.count)
    }

    @Test func testZeroVarianceColumnNoNan() {
        let x: [[Double]] = [[1, 5], [2, 5], [3, 5], [4, 5]]
        let m = LogisticModel.fit(x: x, y: [0, 0, 1, 1], l2: 1.0)
        let s = m.score(x)
        #expect(!s.contains { $0.isNaN } && !m.weights.contains { $0.isNaN })
        #expect(m.std[1] == 1.0 && s[3] > s[0])
    }

    @Test func testGroupPairs() {
        let groups = [5: [1, 2, 3], 6: [4, 5]]
        let pairs = RankingLabels.groupPairs(events: [["image_id": 1, "source": "manual"]], final: [1], groups: groups)
        #expect(pairs.map { [$0.0, $0.1] } == [[1, 2], [1, 3]])
        let none = RankingLabels.groupPairs(events: [["image_id": 4, "source": "auto"]], final: [4], groups: groups)
        #expect(none.isEmpty)
        #expect(RankingLabels.explicit == ["manual", "backfill"])
    }
}
