import Testing
import Metal
import AilbumCore

private func ramp32() -> GrayImage {
    var p = [Float](repeating: 0, count: 32 * 32)
    for y in 0..<32 { for x in 0..<32 { p[y * 32 + x] = Float((x * 7 + y * 13) % 256) } }
    return GrayImage(width: 32, height: 32, pixels: p)
}

@Test func testBlurParity() throws {
    let s = try ScaleSpace.build(ramp32(), layers: 3, sigma: 1.6)
    let g = s.gaussians[0][0]
    #expect(g.width == 64 && g.height == 64)
    let golden: [(Int, Int, Float)] = [(0, 0, 6.0114), (63, 0, 218.7938), (0, 63, 145.1966), (63, 63, 101.9886),
        (1, 1, 8.7676), (10, 20, 160.0), (31, 32, 55.5), (5, 60, 146.4148), (60, 5, 219.3290), (33, 17, 220.5933)]
    for (x, y, v) in golden { #expect(abs(g.pixels[y * 64 + x] - v) < 1e-2) }
}

@Test func testDogIsDifference() throws {
    let s = try ScaleSpace.build(ramp32(), layers: 3, sigma: 1.6)
    for o in 0..<s.gaussians.count {
        #expect(s.dogs[o].count == 5 && s.gaussians[o].count == 6)
        for i in 0..<5 {
            let a = s.gaussians[o][i + 1].pixels, b = s.gaussians[o][i].pixels
            #expect(s.dogs[o][i].pixels == zip(a, b).map { $0 - $1 })
        }
    }
}

@Test func testOctaveDownsample() throws {
    let s = try ScaleSpace.build(ramp32(), layers: 3, sigma: 1.6)
    let src = s.gaussians[0][3], dst = s.gaussians[1][0]
    #expect(dst.width == src.width / 2)
    for y in 0..<dst.height { for x in 0..<dst.width {
        #expect(dst.pixels[y * dst.width + x] == src.pixels[2 * y * src.width + 2 * x])
    } }
}

@Test func testShape() throws {
    let s = try ScaleSpace.build(GrayImage(width: 64, height: 64, pixels: [Float](repeating: 0, count: 4096)), layers: 3, sigma: 1.6)
    #expect(s.gaussians.count == 6 && s.firstOctave == -1)
    #expect(s.gaussians[0][0].width == 128 && s.gaussians[1][0].width == 64 && s.dogs[0].count == 5)
}

@Test func testTinyImage() throws {
    let s = try ScaleSpace.build(GrayImage(width: 8, height: 8, pixels: [Float](repeating: 1, count: 64)), layers: 3, sigma: 1.6)
    #expect(s.gaussians.count >= 1)
}

@Test func testGrayFloat() {
    let g = ScaleSpace.grayFloat(RGBImage(width: 1, height: 1, pixels: [255, 0, 0]))
    #expect(g.pixels == [76.0])
}

@Test func testPipelineFromSource() throws {
    guard MetalContext.shared.device != nil else { return }
    let src = "#include <metal_stdlib>\nusing namespace metal;\nkernel void k1(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] = 2.0f; }"
    let p1 = try MetalContext.shared.pipeline("k1", source: src)
    let p2 = try MetalContext.shared.pipeline("k1", source: src)
    #expect(p1 === p2)
    #expect(throws: AilbumError.self) { try MetalContext.shared.pipeline("nope", source: src) }
}
