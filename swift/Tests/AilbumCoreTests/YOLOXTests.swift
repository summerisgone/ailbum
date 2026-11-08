import Foundation
import Testing
@testable import AilbumCore

private let rows = 8400
private let cols = 85

// (row, col) of a stride-8 cell in the 80x80 grid
private func idx8(_ row: Int, _ col: Int) -> Int { row * 80 + col }

private func output(_ cells: [(index: Int, dx: Float, dy: Float, w: Float, h: Float, obj: Float, cls: Int, p: Float)]) -> [Float] {
    var out = [Float](repeating: 0, count: rows * cols)
    for c in cells {
        let b = c.index * cols
        out[b] = c.dx; out[b + 1] = c.dy; out[b + 2] = c.w; out[b + 3] = c.h
        out[b + 4] = c.obj; out[b + 5 + c.cls] = c.p
    }
    return out
}

private let ln4 = Float(log(4.0))

@Suite struct YOLOXTests {
    @Test func decodeExample() {
        let out = output([(0, 0, 0, Float(log(8.0)), Float(log(8.0)), 0.9, 0, 0.9)])
        let r = YOLOX.decode(out, scale: 1, width: 640, height: 480)
        #expect(r.count == 1)
        #expect(r[0].label == "person")
        #expect(abs(r[0].score - 0.81) < 1e-5)
        #expect(abs(r[0].bbox.x) < 1e-6 && abs(r[0].bbox.y) < 1e-6)
        #expect(abs(r[0].bbox.z - 32.0 / 640) < 1e-6)
        #expect(abs(r[0].bbox.w - 32.0 / 480) < 1e-6)
    }

    @Test func testBatchedNms() {
        let a = idx8(10, 10), b = idx8(10, 11)
        let diff = YOLOX.decode(output([
            (a, 0, 0, ln4, ln4, 0.9, 0, 0.9), (b, 0, 0, ln4, ln4, 0.9, 1, 0.8),
        ]), scale: 1, width: 640, height: 640)
        #expect(diff.count == 2)
        let same = YOLOX.decode(output([
            (a, 0, 0, ln4, ln4, 0.9, 0, 0.9), (b, 0, 0, ln4, ln4, 0.9, 0, 0.8),
        ]), scale: 1, width: 640, height: 640)
        #expect(same.count == 1)
        #expect(abs(same[0].score - 0.81) < 1e-5)
    }

    @Test func testSortOrder() {
        // lower score at the lower index, higher score later
        let r = YOLOX.decode(output([
            (idx8(10, 10), 0, 0, ln4, ln4, 0.9, 0, 0.8),
            (idx8(10, 30), 0, 0, ln4, ln4, 0.9, 0, 0.9),
        ]), scale: 1, width: 640, height: 640)
        #expect(r.count == 2)
        #expect(r[0].score > r[1].score)
        // equal score: smaller bbox first; stride-16 cell (5,10) -> x 160, stride-8 (10,30) -> x 240
        let t = YOLOX.decode(output([
            (idx8(10, 30), 0, 0, ln4, ln4, 0.9, 0, 0.9),
            (6400 + 5 * 40 + 10, 0, 0, ln4, ln4, 0.9, 0, 0.9),
        ]), scale: 1, width: 640, height: 640)
        #expect(t.count == 2)
        #expect(t[0].bbox.x < t[1].bbox.x)
    }

    @Test func testShapeMismatch() {
        #expect(YOLOX.decode([Float](repeating: 0, count: rows * cols - 1), scale: 1, width: 10, height: 10).isEmpty)
        #expect(YOLOX.decode([], scale: 1, width: 10, height: 10).isEmpty)
    }

    @Test func testLetterboxParity() {
        let w = 300, h = 200
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 3
            px[i] = UInt8(x * 255 / 299); px[i + 1] = UInt8(y * 255 / 199); px[i + 2] = UInt8((x + y) * 255 / 498)
        } }
        let (canvas, scale) = YOLOX.letterbox(RGBImage(width: w, height: h, pixels: px))
        #expect(abs(scale - 640.0 / 300) < 1e-5)
        #expect(canvas.width == 640 && canvas.height == 640)
        let golden: [Int] = [0,0,0,23,0,14,48,0,29,73,0,43,97,0,58,121,0,73,145,0,87,170,0,102,194,0,116,219,0,131,243,0,145,0,31,12,23,31,27,48,31,41,73,31,56,97,31,70,121,31,85,145,31,100,170,31,114,194,31,129,219,31,143,243,31,158,0,63,25,23,63,39,48,63,54,73,63,69,97,63,83,121,63,98,145,63,113,170,63,127,194,63,142,219,63,156,243,63,171,0,94,37,23,94,52,48,94,67,73,94,81,97,94,96,121,94,111,145,94,125,170,94,140,194,94,155,219,94,169,243,94,184,0,126,50,23,126,65,48,126,79,72,126,94,97,126,109,121,126,123,145,126,138,170,126,153,194,126,167,219,126,182,243,126,197,0,158,63,23,158,77,48,158,92,72,158,107,97,158,121,121,158,136,145,158,151,170,158,165,194,158,180,219,158,195,243,158,209,0,189,75,23,189,90,48,189,105,72,189,119,97,189,134,121,189,149,145,189,163,170,189,178,194,189,193,219,189,207,243,189,222,0,221,88,23,221,103,48,221,117,72,221,132,97,221,146,121,221,161,145,221,176,170,221,190,194,221,205,219,221,220,243,221,235,0,253,101,23,253,115,48,253,130,72,253,144,97,253,159,121,253,174,145,253,188,170,253,203,194,253,218,219,253,232,243,253,247,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114,114]
        var k = 0
        var worst = 0
        for y in stride(from: 0, to: 640, by: 53) { for x in stride(from: 0, to: 640, by: 61) {
            for c in 0..<3 {
                worst = max(worst, abs(Int(canvas.pixels[(y * 640 + x) * 3 + c]) - golden[k])); k += 1
            }
        } }
        #expect(k == golden.count)
        #expect(worst <= 1)
    }

    @Test(.enabled(if: ModelStore.available("yolox")))
    func detectRuns() throws {
        let img = RGBImage(width: 64, height: 48, pixels: [UInt8](repeating: 128, count: 64 * 48 * 3))
        _ = try YOLOX.detect(img)
    }
}
