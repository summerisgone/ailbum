import Foundation
import Testing
@testable import AilbumCore

private func makeSpace(firstOctave: Int = 0, size: Int = 24, edit: (inout GrayImage) -> Void) -> ScaleSpace {
    let zero = GrayImage(width: size, height: size, pixels: [Float](repeating: 0, count: size * size))
    var dogs = [GrayImage](repeating: zero, count: 5)
    edit(&dogs[2])
    return ScaleSpace(firstOctave: firstOctave, layers: 3, sigma: 1.6,
                      gaussians: [[GrayImage](repeating: zero, count: 6)], dogs: [dogs])
}

private func setPixel(_ img: inout GrayImage, _ x: Int, _ y: Int, _ v: Float) {
    img.pixels[y * img.width + x] = v
}

@Test func testSinglePeak() {
    let space = makeSpace { setPixel(&$0, 12, 12, 40) }
    let kps = SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10)
    #expect(kps.count == 1)
    let k = kps[0]
    #expect(abs(k.x - 12) < 0.01 && abs(k.y - 12) < 0.01)
    #expect(k.octave == 0 && k.layer == 2 && k.angle == -1)
    #expect(abs(k.response - 40.0 / 255.0 * 1.0) < 0.01)
}

@Test func testBorderSkipped() {
    let space = makeSpace { setPixel(&$0, 3, 12, 40) }
    #expect(SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10).isEmpty)
}

@Test func testEdgeRejected() {
    let space = makeSpace { img in for r in 0..<24 { setPixel(&img, 12, r, 40) } }
    #expect(SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10).isEmpty)
}

@Test func testLowContrastRejected() {
    let space = makeSpace { setPixel(&$0, 12, 12, 0.05) }
    #expect(SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10).isEmpty)
}

@Test func testMinimumPeak() {
    let space = makeSpace { setPixel(&$0, 12, 12, -40) }
    let kps = SiftDetector.findExtrema(space, contrastThreshold: 0.02, edgeThreshold: 10)
    #expect(kps.count == 1)
}

@Test func testUpsampledOctaveScales() {
    let base = SiftDetector.findExtrema(makeSpace { setPixel(&$0, 12, 12, 40) }, contrastThreshold: 0.02, edgeThreshold: 10)
    let up = SiftDetector.findExtrema(makeSpace(firstOctave: -1) { setPixel(&$0, 12, 12, 40) }, contrastThreshold: 0.02, edgeThreshold: 10)
    #expect(up.count == 1)
    #expect(abs(up[0].x - 6) < 0.01 && abs(up[0].y - 6) < 0.01)
    #expect(abs(up[0].size - base[0].size * 0.5) < 1e-4)
    #expect(up[0].octave == -1)
}
