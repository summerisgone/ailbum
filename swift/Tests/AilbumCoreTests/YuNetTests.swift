import Foundation
import Testing
@testable import AilbumCore

private func outputs(cells: [(stride: Int, row: Int, col: Int, cls: Float, obj: Float, w: Float)]) -> [String: [Float]] {
    var out: [String: [Float]] = [:]
    for s in [8, 16, 32] {
        let n = (640 / s) * (640 / s)
        out["cls_\(s)"] = [Float](repeating: 0, count: n)
        out["obj_\(s)"] = [Float](repeating: 0, count: n)
        out["bbox_\(s)"] = [Float](repeating: 0, count: n * 4)
        out["kps_\(s)"] = [Float](repeating: 0, count: n * 10)
    }
    for c in cells {
        let g = 640 / c.stride
        let i = c.row * g + c.col
        out["cls_\(c.stride)"]![i] = c.cls
        out["obj_\(c.stride)"]![i] = c.obj
        out["bbox_\(c.stride)"]![i * 4 + 2] = c.w
        out["bbox_\(c.stride)"]![i * 4 + 3] = c.w
    }
    return out
}

@Suite struct YuNetTests {
    @Test func testExample() {
        let o = outputs(cells: [(8, 10, 20, 0.9, 0.9, log(4))])
        let r = YuNet.decode(o, inputSize: 640, scale: 1, scoreThreshold: 0.75, nmsThreshold: 0.3, topK: 5000)
        #expect(r.count == 1)
        #expect(r[0].bbox == (x: 144, y: 64, w: 32, h: 32))
        #expect(abs(r[0].confidence - 0.9) < 1e-5)
        #expect(r[0].landmarks == Array(repeating: SIMD2<Float>(160, 80), count: 5))
    }

    @Test func testNmsSuppresses() {
        // 32x32 boxes at cx 160 and cx 164 (cols 20 and 20.5 -> use stride 8 col 20 and stride 4-offset via bbox0)
        var o = outputs(cells: [(8, 10, 20, 0.9, 0.9, log(4)), (8, 10, 21, 0.8, 0.8, log(4))])
        // shift second box left by 0.5 cell so cx = 164 -> IoU = 28/36 = 0.78
        o["bbox_8"]![(10 * 80 + 21) * 4] = -0.5
        let r = YuNet.decode(o, inputSize: 640, scale: 1, scoreThreshold: 0.75, nmsThreshold: 0.3, topK: 5000)
        #expect(r.count == 1)
        #expect(abs(r[0].confidence - 0.9) < 1e-5)
    }

    @Test func testScaleBack() {
        let o = outputs(cells: [(8, 10, 20, 0.9, 0.9, log(4))])
        let r = YuNet.decode(o, inputSize: 640, scale: 0.5, scoreThreshold: 0.75, nmsThreshold: 0.3, topK: 5000)
        #expect(r[0].bbox == (x: 288, y: 128, w: 64, h: 64))
        #expect(r[0].landmarks[0] == SIMD2<Float>(320, 160))
    }

    @Test func testClipToImage() {
        let d = FaceDetection(bbox: (x: -5, y: 10, w: 50, h: 100), confidence: 0.9, landmarks: [])
        let small = FaceDetection(bbox: (x: 10, y: 10, w: 30, h: 100), confidence: 0.9, landmarks: [])
        let r = YuNet.finalize([d, small], width: 40, height: 60, minFaceSize: 40)
        #expect(r.count == 1)
        #expect(r[0].bbox == (x: 0, y: 10, w: 40, h: 50))
        #expect(YuNet.finalize([d], width: 40, height: 60, minFaceSize: 41).isEmpty)
    }

    @Test func testThreshold() {
        let o = outputs(cells: [(16, 5, 5, 0.74, 0.74, 0)])
        #expect(YuNet.decode(o, inputSize: 640, scale: 1, scoreThreshold: 0.75, nmsThreshold: 0.3, topK: 5000).isEmpty)
        #expect(YuNet.decode(o, inputSize: 640, scale: 1, scoreThreshold: 0.7, nmsThreshold: 0.3, topK: 5000).count == 1)
    }
}
