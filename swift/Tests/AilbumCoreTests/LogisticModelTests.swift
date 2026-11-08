import Testing
import Foundation
@testable import AilbumCore

@Suite struct LogisticModelTests {
    static let x: [[Double]] = [[0, 1], [1, 0], [2, 2], [3, 1], [0, 0], [4, 3]]
    static let y: [Double] = [0, 0, 1, 1, 0, 1]

    @Test func testFitParity() {
        let m = LogisticModel.fit(x: Self.x, y: Self.y, l2: 1.0)
        let w = [0.9667559531645769, 0.7351569339447428]
        let mean = [1.6666666666666667, 1.1666666666666667]
        let std = [1.4907119849998596, 1.0671873729054748]
        for i in 0..<2 {
            #expect(abs(m.weights[i] - w[i]) < 1e-8)
            #expect(abs(m.mean[i] - mean[i]) < 1e-8)
            #expect(abs(m.std[i] - std[i]) < 1e-8)
        }
        #expect(abs(m.bias - 0.10678259308629648) < 1e-8)
        let s = m.score([[1, 1], [5, 0]])
        #expect(abs(s[0] - 0.3916513708952492) < 1e-8)
        #expect(abs(s[1] - 0.8122701551522191) < 1e-8)
    }

    @Test func testConstantFeature() {
        let x: [[Double]] = [[0, 5], [1, 5], [2, 5], [3, 5]]
        let m = LogisticModel.fit(x: x, y: [0, 0, 1, 1], l2: 1.0)
        #expect(m.std[1] == 1.0)
        #expect(m.weights.allSatisfy { $0.isFinite })
        #expect(m.score(x).allSatisfy { $0.isFinite })
    }

    @Test func testScoreClip() {
        let m = LogisticModel(weights: [1], bias: 0, mean: [0], std: [1])
        let s = m.score([[1000]])
        #expect(s[0] == 1 / (1 + exp(-30.0)))
    }

    @Test func testJSONFromPython() throws {
        let d: [String: Any] = ["weights": [0.5, -0.25], "bias": 0.1, "mean": [1.0, 2.0],
                                "std": [2.0, 4.0], "feature_version": 3, "feature_names": ["a", "b"]]
        let m = try LogisticModel.fromJSON(d)
        let s = m.score([[3, 1], [0, 9]])
        #expect(abs(s[0] - 0.6598217549720575) < 1e-12)
        #expect(abs(s[1] - 0.35720867575922377) < 1e-12)
        #expect(m.featureVersion == 3)
        #expect(m.featureNames == ["a", "b"])
    }

    @Test func testJSONKeys() {
        let j = LogisticModel.fit(x: Self.x, y: Self.y, l2: 1.0).toJSON()
        #expect(Set(j.keys) == ["weights", "bias", "mean", "std", "feature_version", "feature_names"])
    }

    @Test func testJSONMissingKeyThrows() {
        #expect(throws: (any Error).self) { try LogisticModel.fromJSON(["bias": 1.0]) }
    }
}
