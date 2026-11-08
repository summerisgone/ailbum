import Foundation
import Testing
@testable import AilbumCore

private func c(_ id: Int, _ score: Double, _ story: Int?, _ cluster: Int?, _ emb: [Double]?) -> RankingCandidate {
    RankingCandidate(imageId: id, score: score, storyId: story, similarCluster: cluster, embedding: emb)
}

private let base = [c(1, 0.9, 1, nil, nil), c(2, 0.8, 1, nil, nil), c(3, 0.5, 2, nil, nil)]

@Suite struct RankingSelectTests {
    @Test func testPlanExamples() {
        #expect(RankingSelect.selectForTarget(base, target: 2, keep: []) == [1, 3])
        #expect(RankingSelect.selectForTarget(base, target: 2, keep: [2]) == [2, 3])
    }

    @Test func testKeepAllEvenOverTargetAndUnknown() {
        #expect(RankingSelect.selectForTarget(base, target: 1, keep: [2, 99]) == [2, 99])
    }

    @Test func testExhaustedCandidates() {
        #expect(RankingSelect.selectForTarget(base, target: 10, keep: []) == [1, 3, 2])
    }

    @Test func testEmbeddingPenalty() {
        let cands = [c(1, 0.9, nil, nil, [1, 0]), c(2, 0.8, nil, nil, [1, 0]), c(3, 0.6, nil, nil, [0, 1])]
        #expect(RankingSelect.selectForTarget(cands, target: 2, keep: []) == [1, 3])
    }

    @Test func testSimilarClusterNotTwiceWhileOthersRemain() {
        let cands = [c(1, 0.9, nil, 7, nil), c(2, 0.8, nil, 7, nil), c(3, 0.1, nil, nil, nil)]
        #expect(RankingSelect.selectForTarget(cands, target: 2, keep: []) == [1, 3])
        #expect(RankingSelect.selectForTarget(cands, target: 3, keep: []) == [1, 3, 2])
    }

    @Test func testTiesByImageId() {
        let cands = [c(5, 0.5, nil, nil, nil), c(4, 0.5, nil, nil, nil)]
        #expect(RankingSelect.selectForTarget(cands, target: 1, keep: []) == [4])
    }

    private func tempDB() throws -> Database {
        let dir = NSTemporaryDirectory() + "ailbum-\(UUID().uuidString)"
        return try Database.open(path: dir + "/c.sqlite3")
    }

    private func model(_ version: Int) -> LogisticModel {
        LogisticModel(weights: [1, 2], bias: 0.5, mean: [0, 0], std: [1, 1], featureVersion: version, featureNames: ["a", "b"])
    }

    @Test func testActiveModelRoundTripAndDeactivate() throws {
        let db = try tempDB()
        #expect(try RankingStore.activeModel(db, kind: "pairwise") == nil)
        let m = model(RankingStore.featureVersion)
        let first = try RankingStore.saveModel(db, kind: "pairwise", model: m, metrics: ["n": .int(1)], active: true)
        #expect(first == 1)
        let got = try #require(try RankingStore.activeModel(db, kind: "pairwise"))
        #expect(got.id == 1)
        #expect(got.model.weights == [1, 2] && got.model.bias == 0.5)
        let second = try RankingStore.saveModel(db, kind: "pairwise", model: m, metrics: [:], active: true)
        #expect(second == 2)
        #expect(try RankingStore.activeModel(db, kind: "pairwise")?.id == 2)
        let rows = try db.query("SELECT active FROM ranking_models WHERE id = 1", [])
        #expect(rows.first?["active"] == .integer(0))
        _ = try RankingStore.saveModel(db, kind: "pointwise", model: m, metrics: [:], active: true)
        #expect(try RankingStore.activeModel(db, kind: "pairwise")?.id == 2)
    }

    @Test func testStaleFeatureVersionIsNil() throws {
        let db = try tempDB()
        _ = try RankingStore.saveModel(db, kind: "pairwise", model: model(RankingStore.featureVersion + 1),
                                       metrics: [:], active: true)
        #expect(try RankingStore.activeRow(db, kind: "pairwise") == nil)
        #expect(try RankingStore.activeModel(db, kind: "pairwise") == nil)
    }
}
