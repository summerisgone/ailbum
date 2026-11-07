import Foundation
import Testing
@testable import AilbumCore

private func gridFeatures(count: Int = 100) -> GeometricFeatures {
    var kps: [SIMD2<Float>] = []
    var desc = [Float](repeating: 0, count: count * 128)
    for i in 0..<count {
        kps.append(SIMD2(Float(50 + (i % 10) * 10), Float(50 + (i / 10) * 10)))
        desc[i * 128 + i] = 100
    }
    return GeometricFeatures(keypoints: kps, descriptors: desc, width: 200, height: 200)
}

private func photo(_ bits: Int, geometric: GeometricFeatures? = nil, hist: [Float] = [1, 0]) -> PhotoFeatures {
    PhotoFeatures(phash: (0..<64).map { $0 < bits }, histogram: hist, geometric: geometric)
}

@Suite struct SimilarityTests {
    @Test func testScoreFormula() throws {
        let f = gridFeatures()
        let g = try Similarity.geometric(f, f)
        #expect(g.inliers == 100)
        #expect(g.mutualMatches == 100)
        #expect(g.inlierRatio == 1)
        #expect(abs(g.coverageLeft - 0.2025) < 1e-3)
        #expect(abs(g.coverageRight - 0.2025) < 1e-3)
        let expected = (1 - exp(-100.0 / 80.0)) * min(0.2025 / 0.25, 1)
        #expect(abs(g.score - expected) < 1e-3)
    }

    @Test func testFewMutual() throws {
        let f = gridFeatures(count: 3)
        let g = try Similarity.geometric(f, f)
        #expect(g.mutualMatches == 3)
        #expect(g.score == 0)
    }

    @Test func testNilIsEmpty() throws {
        #expect(try Similarity.geometric(nil, gridFeatures()) == .empty)
    }

    @Test func testCandidate() {
        #expect(Similarity.isGeometricCandidate(hash: 30, color: 0.7))
        #expect(!Similarity.isGeometricCandidate(hash: 30, color: 0.5))
        #expect(Similarity.isGeometricCandidate(hash: 24, color: 0))
    }

    private func windowGroups(_ lateTime: String) throws -> [[Int]] {
        let f = gridFeatures()
        var photos = (0..<21).map { _ in photo(30, hist: [0, 1]) }
        photos[0] = photo(0, geometric: f, hist: [0.7, 0.7])
        photos[20] = photo(10, geometric: f, hist: [0.7, 0.7])
        for i in 1..<20 { photos[i] = photo(64, hist: [1, 0]) }
        var times = [String?](repeating: nil, count: 21)
        times[0] = "2024-05-01T10:00:00"
        times[20] = lateTime
        return try Similarity.cluster(photos, hashDistance: 0, histogramThreshold: 2, geometricThreshold: 0.55,
                                      captureTimes: times)
    }

    @Test func testWindowByTime() throws {
        #expect(try windowGroups("2024-05-01T10:10:00").contains([0, 20]))
        #expect(!(try windowGroups("2024-05-01T10:30:00").contains([0, 20])))
    }

    @Test func testHashColorUnion() throws {
        let photos = [photo(5), photo(5)]
        #expect(try Similarity.cluster(photos, hashDistance: 0, histogramThreshold: 0.9) == [[0, 1]])
    }

    @Test func testInvalidWindow() {
        #expect(throws: AilbumError.self) {
            try Similarity.cluster([photo(1)], hashDistance: 0, histogramThreshold: 0.9, neighborWindow: 0)
        }
        #expect(throws: AilbumError.self) {
            try Similarity.cluster([photo(1)], hashDistance: 0, histogramThreshold: 0.9, timeWindowMinutes: 0)
        }
    }

    @Test func testTimesLengthMismatch() {
        #expect(throws: AilbumError.self) {
            try Similarity.cluster([photo(1), photo(2)], hashDistance: 0, histogramThreshold: 0.9, captureTimes: ["2024-05-01T10:00:00"])
        }
    }
}
