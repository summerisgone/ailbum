import Testing
import AilbumCore

private func syntheticImage() -> RGBImage {
    let w = 64, h = 48
    var px = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h {
        for x in 0..<w {
            let v = UInt8((x * x + 3 * y) % 256)
            let i = (y * w + x) * 3
            px[i] = v; px[i + 1] = v; px[i + 2] = v
        }
    }
    return RGBImage(width: w, height: h, pixels: px)
}

private func solid(_ w: Int, _ h: Int, _ v: UInt8) -> RGBImage {
    RGBImage(width: w, height: h, pixels: [UInt8](repeating: v, count: w * h * 3))
}

@Test func testSharpnessUniform() throws {
    #expect(try Quality.sharpness(solid(64, 64, 128), maxSide: 1600) == 0.0)
}

@Test func testSharpnessParity() throws {
    let s = try Quality.sharpness(syntheticImage(), maxSide: 1600)
    #expect(abs(s - 2085.413384331597) / 2085.413384331597 < 1e-3)
}

@Test func testExposureParity() {
    let e = Quality.exposure(syntheticImage(), maxSide: 800)
    #expect(abs(e - 0.9474701126416524) < 1e-4)
}

@Test func testExposureBlack() {
    #expect(abs(Quality.exposure(solid(16, 16, 0), maxSide: 800)) < 1e-12)
}

@Test func testNegativeSharpnessClamped() {
    #expect(abs(Quality.score(sharpness: -5, exposure: 1) - 0.2) < 1e-12)
}

@Test func testScoreExamples() {
    #expect(abs(Quality.score(sharpness: 1000, exposure: 1) - 1.0) < 1e-12)
    #expect(abs(Quality.score(sharpness: 0, exposure: 0.5) - 0.1) < 1e-12)
}

@Test func testMetalAvailable() throws {
    _ = try MetalContext.shared.pipeline("laplacian")
}

private func noisy(_ w: Int, _ h: Int) -> RGBImage {
    var v: UInt64 = 7
    var px = [UInt8]()
    for _ in 0..<(w * h * 3) {
        v = (v * 1103515245 + 12345) & 0x7fffffff
        px.append(UInt8((v >> 16) & 255))
    }
    return RGBImage(width: w, height: h, pixels: px)
}

@Test func testTinyImageBordersParity() throws {
    let cases: [(Int, Int, Double, Double)] = [
        (5, 2, 53.360000000000014, 0.9788235306739808),
        (2, 5, 50.64, 0.9788235306739808),
        (1, 6, 978.1388888888888, 0.9545098066329956),
        (6, 1, 978.1388888888888, 0.9545098066329956),
    ]
    for (w, h, sharp, expo) in cases {
        let s = try Quality.sharpness(noisy(w, h), maxSide: 1600)
        #expect(abs(s - sharp) / sharp < 1e-3, "sharpness \(w)x\(h) got \(s)")
        #expect(abs(Quality.exposure(noisy(w, h), maxSide: 800) - expo) < 1e-4, "exposure \(w)x\(h)")
    }
}

@Test func testEmptyImageDoesNotTrap() throws {
    let empty = RGBImage(width: 0, height: 0, pixels: [])
    #expect(try Quality.sharpness(empty, maxSide: 100) == 0)
    #expect(Quality.exposure(empty, maxSide: 100) == 0)
}
