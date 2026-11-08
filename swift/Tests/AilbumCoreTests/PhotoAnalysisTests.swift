import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AilbumCore

private func stripes(_ w: Int, _ h: Int, _ step: Int) -> RGBImage {
    var px = [UInt8](repeating: 0, count: w * h * 3)
    for x in stride(from: step, to: w - step, by: step) {
        for y in 10..<(h - 9) {
            for dx in -1...1 {
                let i = (y * w + x + dx) * 3
                px[i] = 255; px[i + 1] = 200; px[i + 2] = 20
            }
        }
    }
    return RGBImage(width: w, height: h, pixels: px)
}

private func writePNG(_ image: RGBImage, to url: URL) throws {
    let provider = CGDataProvider(data: Data(image.pixels) as CFData)!
    let cg = CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24,
        bytesPerRow: image.width * 3, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func analyzed(_ w: Int, _ h: Int, _ step: Int, threshold: Double = 100) throws -> PhotoRecord {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.png")
    try writePNG(stripes(w, h, step), to: file)
    var config = PipelineConfig()
    config.sharpnessThreshold = threshold
    config.photoGeometricSimilarity = nil
    return try PhotoAnalysis.analyze(
        path: file.path, photoId: "photo-00001", takenAt: "2024-01-01T00:00:00", config: config,
        faceBackend: "off"
    ).record
}

@Test func testNumericParityUnresized() throws {
    let r = try analyzed(320, 320, 20)
    #expect(r.width == 320 && r.height == 320)
    #expect(abs(r.sharpness - 997.355) < 2e-2)
    #expect(abs(r.exposure - 0.148) < 2e-2)
    #expect(abs(r.quality - 0.8293) < 2e-2)
    #expect(r.faces.isEmpty)
    #expect(r.semantics == nil)
    #expect(r.composition != nil && r.color != nil)
    #expect(r.takenAt == "2024-01-01T00:00:00")
}

@Test func testNumericParityResized() throws {
    let r = try analyzed(1800, 1200, 60)
    #expect(abs(r.sharpness - 353.171) / 353.171 < 2e-2)
    #expect(abs(r.exposure - 0.0793) < 2e-2)
    #expect(abs(r.quality - 0.6956) < 2e-2)
}

@Test func testBlurryUsesStrictLess() throws {
    let s = try analyzed(320, 320, 20).sharpness
    #expect(try analyzed(320, 320, 20, threshold: s - 0.01).isBlurry == false)
    #expect(try analyzed(320, 320, 20, threshold: s + 0.01).isBlurry == true)
}

@Test func testFaceBackendResolution() throws {
    #expect(try PhotoAnalysis.faceBackend("off") == "off")
    #expect(try PhotoAnalysis.faceBackend("classic") == "off")
    let ready = ModelStore.available("yunet") && ModelStore.available("sface")
    #expect(try PhotoAnalysis.faceBackend("auto") == (ready ? "dnn" : "off"))
    #expect(throws: AilbumError.self) { try PhotoAnalysis.faceBackend("x") }
    if !ready {
        #expect(throws: AilbumError.self) { try PhotoAnalysis.faceBackend("dnn") }
    }
}

@Test func testSemanticBackendResolution() throws {
    #expect(try PhotoAnalysis.semanticBackend("off") == "off")
    #expect(try PhotoAnalysis.semanticBackend("clip") == "clip")
    #expect(throws: AilbumError.self) { try PhotoAnalysis.semanticBackend("x") }
    let r = try PhotoAnalysis.semanticBackend("auto")
    #expect(r == "clip" || r == "off")
}
