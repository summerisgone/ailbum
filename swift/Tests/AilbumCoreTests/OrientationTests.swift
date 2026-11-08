import Foundation
import Testing
@testable import AilbumCore

private func spaceWith(size: Int = 40, _ f: (Int, Int) -> Float) -> ScaleSpace {
    var px = [Float](repeating: 0, count: size * size)
    for y in 0..<size { for x in 0..<size { px[y * size + x] = f(x, y) } }
    let img = GrayImage(width: size, height: size, pixels: px)
    let dog = GrayImage(width: size, height: size, pixels: [Float](repeating: 0, count: size * size))
    return ScaleSpace(firstOctave: 0, layers: 3, sigma: 1.6,
                      gaussians: [[GrayImage](repeating: img, count: 6)],
                      dogs: [[GrayImage](repeating: dog, count: 5)])
}

private func kp(x: Float = 20, y: Float = 20, response: Float = 1, size: Float = 3.2, angle: Float = -1) -> SiftKeypoint {
    SiftKeypoint(x: x, y: y, size: size, angle: angle, response: response, octave: 0, layer: 1, subLayer: 0)
}

private func angleDiff(_ a: Float, _ b: Float) -> Float {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
}

@Test func testHorizontalRamp() {
    let out = SiftDetector.assignOrientations([kp()], space: spaceWith { x, _ in Float(x) * 4 })
    #expect(out.count == 1)
    #expect(angleDiff(out[0].angle, 0) < 5)
}

@Test func testVerticalRamp() {
    // OpenCV: dy = img(y-1) - img(y+1) = -8 -> -90 deg -> bin 27 -> angle 360 - 270
    let out = SiftDetector.assignOrientations([kp()], space: spaceWith { _, y in Float(y) * 4 })
    #expect(out.count == 1)
    #expect(angleDiff(out[0].angle, 90) < 5)
}

@Test func testTwoPeaks() {
    let out = SiftDetector.assignOrientations([kp()], space: spaceWith { x, _ in 4 * abs(Float(x) - 20) })
    #expect(out.count == 2)
    #expect(out[0].x == out[1].x && out[0].y == out[1].y)
    let angles = out.map(\.angle).sorted()
    #expect(angleDiff(angles[0], 0) < 5)
    #expect(angleDiff(angles[1], 180) < 5)
}

@Test func testRetainBest() {
    let kps = [0.1, 0.5, 0.3].enumerated().map { kp(x: Float($0.offset), response: Float($0.element)) }
    #expect(SiftDetector.retainBest(kps, maxFeatures: 2).map(\.response) == [0.5, 0.3])
}

@Test func testRetainStable() {
    let kps = (0..<4).map { kp(x: Float($0), response: 1) }
    #expect(SiftDetector.retainBest(kps, maxFeatures: 2).map(\.x) == [0, 1])
}

@Test func testRetainZero() {
    let kps = (0..<5).map { kp(x: Float($0), response: Float($0)) }
    #expect(SiftDetector.retainBest(kps, maxFeatures: 0).count == 5)
}

@Test func testDuplicatesRemoved() {
    let a = kp(response: 1), b = kp(response: 0.5)
    #expect(SiftDetector.retainBest([a, b, kp(x: 3)], maxFeatures: 0).count == 2)
}
