import Testing
@testable import AilbumCore

private struct LCG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
}

private func perspectiveCase() -> (src: [SIMD2<Float>], dst: [SIMD2<Float>], isInlier: [Bool]) {
    var rng = LCG(s: 42)
    let h: [Double] = [1.1, 0.1, 15, -0.05, 0.95, -8, 0.0004, 0.0002, 1]
    var src: [SIMD2<Float>] = [], dst: [SIMD2<Float>] = [], flags: [Bool] = []
    for i in 0..<30 {
        let x = rng.next() * 300, y = rng.next() * 200
        let w = h[6] * x + h[7] * y + h[8]
        var px = (h[0] * x + h[1] * y + h[2]) / w
        var py = (h[3] * x + h[4] * y + h[5]) / w
        let outlier = i % 10 < 3
        if outlier {
            px += 40 + rng.next() * 60
            py -= 40 + rng.next() * 60
        } else {
            px += rng.next() - 0.5
            py += rng.next() - 0.5
        }
        src.append(SIMD2(Float(x), Float(y)))
        dst.append(SIMD2(Float(px), Float(py)))
        flags.append(!outlier)
    }
    return (src, dst, flags)
}

@Suite struct HomographyTests {
    @Test func testFewerThanFour() {
        let p: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
        #expect(Homography.ransacInliers(p, p, threshold: 4, seed: 0x5EED) == nil)
    }

    @Test func testCollinear() {
        let p: [SIMD2<Float>] = (0..<10).map { SIMD2(Float($0), Float($0) * 2 + 1) }
        #expect(Homography.ransacInliers(p, p, threshold: 4, seed: 0x5EED) == nil)
    }

    @Test func testTranslationWithOutliers() {
        let src: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(50, 3), SIMD2(10, 40), SIMD2(60, 70),
                                   SIMD2(30, 20), SIMD2(80, 10), SIMD2(5, 90), SIMD2(45, 55),
                                   SIMD2(20, 20), SIMD2(70, 30)]
        var dst = src.map { $0 + SIMD2(5, 3) }
        dst[8] += SIMD2(50, 0)
        dst[9] += SIMD2(0, -50)
        let m = Homography.ransacInliers(src, dst, threshold: 4, seed: 0x5EED)
        #expect(m == [true, true, true, true, true, true, true, true, false, false])
    }

    @Test func testPerspective() {
        let c = perspectiveCase()
        let m = Homography.ransacInliers(c.src, c.dst, threshold: 4, seed: 0x5EED)
        #expect(m != nil)
        for (i, ok) in c.isInlier.enumerated() where ok { #expect(m?[i] == true) }
        for (i, ok) in c.isInlier.enumerated() where !ok { #expect(m?[i] == false) }
    }

    @Test func testDeterministic() {
        let c = perspectiveCase()
        let a = Homography.ransacInliers(c.src, c.dst, threshold: 4, seed: 7)
        let b = Homography.ransacInliers(c.src, c.dst, threshold: 4, seed: 7)
        #expect(a == b)
    }

    @Test func testCoverageSquare() {
        let pts: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10), SIMD2(5, 5)]
        #expect(abs(Hull.coverage(pts, width: 20, height: 20) - 0.25) < 1e-12)
    }

    @Test func testCoverageTriangle() {
        let pts: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10)]
        #expect(abs(Hull.coverage(pts, width: 10, height: 10) - 0.5) < 1e-12)
    }

    @Test func testCoverageDegenerate() {
        #expect(Hull.coverage([SIMD2(0, 0), SIMD2(1, 1)], width: 10, height: 10) == 0)
        let sq: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10)]
        #expect(Hull.coverage(sq, width: 0, height: 10) == 0)
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(5, 5), SIMD2(10, 10)]
        #expect(Hull.coverage(line, width: 10, height: 10) == 0)
    }
}
