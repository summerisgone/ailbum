import Foundation
import Testing
@testable import AilbumCore

private struct GoldenFace: Decodable {
    var bbox: [Int]
    var confidence: Double
    var embedding: [Float]
    var landmarks: [Float]
    var left_eye_open_probability: Double?
    var right_eye_open_probability: Double?
    var expression: String?
}

private func fixture(_ name: String) throws -> String {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)).path
}

private func iou(_ a: [Int], _ b: (x: Int, y: Int, w: Int, h: Int)) -> Double {
    let iw = Double(min(a[0] + a[2], b.x + b.w) - max(a[0], b.x))
    let ih = Double(min(a[1] + a[3], b.y + b.h) - max(a[1], b.y))
    guard iw > 0, ih > 0 else { return 0 }
    let inter = iw * ih
    return inter / (Double(a[2] * a[3] + b.w * b.h) - inter)
}

private let modelsReady = ModelStore.available("yunet") && ModelStore.available("sface")
    && ModelStore.available("eye") && ModelStore.available("expression")

@Suite struct FaceParityTests {
    private func run() throws -> ([GoldenFace], [FaceAnalysis]) {
        let golden = try JSONDecoder().decode(
            [String: [GoldenFace]].self, from: Data(contentsOf: URL(fileURLWithPath: fixture("faces_golden.json"))))["faces"]!
        let image = try ImageLoader.load(path: fixture("astronaut.png"))
        return (golden, try FaceAnalyzer.analyze(image, minFaceSize: 40, minAttributeFaceSize: 64))
    }

    @Test(.enabled(if: modelsReady)) func testFaceCount() throws {
        let (g, s) = try run()
        #expect(s.count == g.count)
    }

    @Test(.enabled(if: modelsReady)) func testBoxIoU() throws {
        let (g, s) = try run()
        for (a, b) in zip(g, s) {
            let v = iou(a.bbox, b.detection.bbox)
            print("PARITY iou", v, a.bbox, b.detection.bbox)
            #expect(v >= 0.85)
        }
    }

    @Test(.enabled(if: modelsReady)) func testEmbeddingCosine() throws {
        let (g, s) = try run()
        for (a, b) in zip(g, s) {
            let c = zip(a.embedding, b.embedding).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            print("PARITY cosine", c)
            #expect(c >= 0.98)
        }
    }

    @Test(.enabled(if: modelsReady)) func testAttributes() throws {
        let (g, s) = try run()
        for (a, b) in zip(g, s) {
            print("PARITY attrs", a.expression as Any, b.attributes.expression as Any,
                  a.left_eye_open_probability as Any, b.attributes.leftEyeOpenProbability as Any,
                  a.right_eye_open_probability as Any, b.attributes.rightEyeOpenProbability as Any)
            #expect(b.attributes.expression == a.expression)
            #expect(abs((b.attributes.leftEyeOpenProbability ?? -9) - (a.left_eye_open_probability ?? 9)) < 0.1)
            #expect(abs((b.attributes.rightEyeOpenProbability ?? -9) - (a.right_eye_open_probability ?? 9)) < 0.1)
        }
    }

    @Test(.enabled(if: modelsReady)) func testSmallFaceNoAttributes() throws {
        let image = try ImageLoader.load(path: fixture("astronaut.png"))
        let r = try FaceAnalyzer.analyze(image, minFaceSize: 40, minAttributeFaceSize: 1000)
        #expect(!r.isEmpty)
        for f in r { #expect(f.attributes == FaceAttributes()) }
    }
}
