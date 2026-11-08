import Testing
@testable import AilbumCore

struct AestheticsTests {
    @Test func testFacesSubject() {
        let image = RGBImage(width: 300, height: 200, pixels: [UInt8](repeating: 0, count: 300 * 200 * 3))
        let record = Aesthetics.composition(image, faceBoxes: [SIMD4(100, 50, 40, 40), SIMD4(160, 60, 40, 40)], maxSide: 800)
        let subject = record.mainSubject
        #expect(subject?.bbox == SIMD4(0.3333, 0.25, 0.3333, 0.25))
        #expect(subject?.center == SIMD2(0.5, 0.375))
        #expect(subject?.source == "faces")
        #expect(record.ruleOfThirds == 0.7372)
        #expect(record.frameOccupancy == 0.0833)
        #expect(record.negativeSpace == 0.9167)
        #expect(record.cropRisk == 0.0)
        #expect(record.score == 0.7716)
    }

    @Test func testBoundaryRisk() {
        let image = RGBImage(width: 300, height: 200, pixels: [UInt8](repeating: 0, count: 300 * 200 * 3))
        let record = Aesthetics.composition(image, faceBoxes: [SIMD4(0, 0, 40, 40)], maxSide: 800)
        #expect(record.cropRisk == 1.0)
        #expect(record.ruleOfThirds == 0.2734)
        #expect(record.score == 0.2191)
    }

    @Test func testColorGray() {
        let image = RGBImage(width: 16, height: 16, pixels: [UInt8](repeating: 128, count: 16 * 16 * 3))
        #expect(Aesthetics.color(image, maxSide: 800) == ColorRecord(balance: 1.0, harmony: 1.0, meanSaturation: 0.0))
    }

    @Test func testColorParity() {
        var px = [UInt8]()
        for y in 0..<60 { for x in 0..<80 {
            px += [UInt8((x * 3) % 256), UInt8((y * 4) % 256), UInt8((x * y) % 256)]
        } }
        let c = Aesthetics.color(RGBImage(width: 80, height: 60, pixels: px), maxSide: 800)
        #expect(abs(c.balance - 0.9955) < 1e-4)
        #expect(abs(c.harmony - 0.6063) < 1e-4)
        #expect(abs(c.meanSaturation - 0.6683) < 1e-4)
    }

    @Test func testHarmonyComplementary() {
        var px = [UInt8]()
        for _ in 0..<60 { for x in 0..<80 { px += x < 40 ? [255, 0, 0] : [0, 255, 255] } }
        let c = Aesthetics.color(RGBImage(width: 80, height: 60, pixels: px), maxSide: 800)
        #expect(abs(c.harmony - 0.9862) < 1e-4)
        #expect(c.balance == 1.0)
        #expect(c.meanSaturation == 1.0)
    }

    @Test func testRounding() {
        var px = [UInt8]()
        for y in 0..<60 { for x in 0..<80 {
            px += [UInt8((x * 3) % 256), UInt8((y * 4) % 256), UInt8((x * y) % 256)]
        } }
        let c = Aesthetics.color(RGBImage(width: 80, height: 60, pixels: px), maxSide: 800)
        for v in [c.balance, c.harmony, c.meanSaturation] { #expect((v * 10000).rounded() == v * 10000 || abs(v * 10000 - (v * 10000).rounded()) < 1e-9) }
    }

    @Test func testNoFaceUniform() {
        let image = RGBImage(width: 50, height: 50, pixels: [UInt8](repeating: 50, count: 50 * 50 * 3))
        let record = Aesthetics.composition(image, faceBoxes: [], maxSide: 800)
        #expect(record.mainSubject == nil)
        #expect(record.negativeSpace == 1.0)
        #expect(record.score == 0.0)
    }
}
