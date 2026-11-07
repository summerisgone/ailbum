import Foundation
import Testing
@testable import AilbumCore

private func space(_ img: GrayImage) -> ScaleSpace {
    ScaleSpace(firstOctave: 0, layers: 3, sigma: 1.6, gaussians: [Array(repeating: img, count: 6)], dogs: [])
}

private func kp(_ x: Float, _ y: Float, size: Float = 6, angle: Float = 0) -> SiftKeypoint {
    SiftKeypoint(x: x, y: y, size: size, angle: angle, response: 1, octave: 0, layer: 0, subLayer: 0)
}

private func noisy(_ n: Int) -> GrayImage {
    var px = [Float](repeating: 0, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            let fx = Float(x), fy = Float(y)
            px[y * n + x] = 128 + 40 * sin(fx * 0.37 + fy * 0.11) + 35 * cos(fx * 0.13 - fy * 0.29)
                + 30 * sin(fx * 0.21 * fy * 0.05 + 1) + 20 * cos(fx * 0.5 + fy * 0.43)
        }
    }
    return GrayImage(width: n, height: n, pixels: px)
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var d = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count { d += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
    return d / (na.squareRoot() * nb.squareRoot())
}

@Test func testEmptyAndFlat() {
    let s = space(GrayImage(width: 40, height: 40, pixels: [Float](repeating: 50, count: 1600)))
    #expect(SiftDescriptor.compute([], space: s) == [])
    #expect(SiftDescriptor.compute([kp(20, 20)], space: s) == [Float](repeating: 0, count: 128))
}

@Test func testNormClamp() {
    let d = SiftDescriptor.compute([kp(40, 40)], space: space(noisy(81)))
    #expect(d.count == 128)
    #expect(d.allSatisfy { $0 == $0.rounded() && $0 >= 0 && $0 <= 255 })
    let norm = d.reduce(0) { $0 + Double($1 * $1) }.squareRoot()
    #expect(abs(norm - 512) < 20)
    // a single strong edge would put ~all energy in few bins without clamp
    var px = [Float](repeating: 0, count: 81 * 81)
    for y in 0..<81 { for x in 41..<81 { px[y * 81 + x] = 200 } }
    let e = SiftDescriptor.compute([kp(40, 40)], space: space(GrayImage(width: 81, height: 81, pixels: px)))
    #expect(e.max()! < 255)
    #expect(e.max()! > 0)
}

@Test func testRotationInvariance() {
    let n = 81
    let a = noisy(n)
    var rot = [Float](repeating: 0, count: n * n)
    for y in 0..<n { for x in 0..<n { rot[y * n + x] = a.pixels[x * n + (n - 1 - y)] } }
    let b = GrayImage(width: n, height: n, pixels: rot)
    let da = SiftDescriptor.compute([kp(40, 40, angle: 0)], space: space(a))
    let best = [Float(90), 270].map { ang in
        cosine(da, SiftDescriptor.compute([kp(40, 40, angle: ang)], space: space(b)))
    }.max()!
    #expect(best >= 0.95)
}

@Test func testNearBorder() {
    let s = space(noisy(81))
    let d = SiftDescriptor.compute([kp(2, 2), kp(78, 40), kp(40, 79), kp(0, 0)], space: s)
    #expect(d.count == 512)
    #expect(d.allSatisfy { $0.isFinite })
}

@Test func testCount() {
    let d = SiftDescriptor.compute([kp(30, 30), kp(40, 40), kp(50, 50, angle: 123)], space: space(noisy(81)))
    #expect(d.count == 384)
}

@Test func testManyKeypointsMatchSingle() {
    let s = space(noisy(81))
    var kps: [SiftKeypoint] = []
    for i in 0..<200 {
        let x: Float = Float(5 + i % 70), y: Float = Float(5 + (i * 7) % 70)
        kps.append(kp(x, y, angle: Float(i % 360)))
    }
    let all = SiftDescriptor.compute(kps, space: s)
    #expect(all.count == 200 * 128)
    for i in [0, 57, 199] {
        #expect(Array(all[i * 128..<(i + 1) * 128]) == SiftDescriptor.compute([kps[i]], space: s))
    }
}
