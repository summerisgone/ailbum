import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import AilbumCore

// Same integer formula as the Python golden generator (PNG, lossless).
private func synthetic(_ w: Int, _ h: Int, dx: Int, dy: Int) -> RGBImage {
    var px = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h { for x in 0..<w {
        let xx = x + dx, yy = y + dy
        for c in 0..<3 {
            let base = xx * 7 + yy * 13 + c * 50 + ((xx * yy) >> 3)
            let blocks = (xx / 16 + yy / 16) * 37 + (xx / 16) * (yy / 16) * 11 + c * 29
            px[(y * w + x) * 3 + c] = UInt8((base ^ blocks) & 255)
        }
    } }
    return RGBImage(width: w, height: h, pixels: px)
}

private func writePNG(_ img: RGBImage, to path: String) {
    var rgba = [UInt8](repeating: 255, count: img.width * img.height * 4)
    for i in 0..<(img.width * img.height) { for c in 0..<3 { rgba[i * 4 + c] = img.pixels[i * 3 + c] } }
    let ctx = CGContext(data: &rgba, width: img.width, height: img.height, bitsPerComponent: 8,
                        bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func pair() -> (String, String) {
    let d = NSTemporaryDirectory() + "t13-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    writePNG(synthetic(320, 240, dx: 0, dy: 0), to: d + "/a.png")
    writePNG(synthetic(320, 240, dx: 6, dy: 4), to: d + "/b.png")
    return (d + "/a.png", d + "/b.png")
}

private func keyTree(_ v: JSONValue) -> [String] {
    guard case .object(let o) = v else { return [] }
    return o.keys.sorted().flatMap { k in [k] + keyTree(o[k]!).map { k + "." + $0 } }
}

@Suite struct CompareTests {
    @Test func testSameImageMatches() throws {
        let (a, _) = pair()
        let r = try Compare.images(left: a, right: a, hashDistance: 12, histogramThreshold: 0.72,
                                   geometricThreshold: 0.55, geometricMaxFeatures: 4000, maxImageSide: 1600)
        #expect(r["hash_color"]?["hash_distance"]?.intValue == 0)
        #expect(r["hash_color"]?["similar"]?.boolValue == true)
        #expect(r["geometric_scene_overlap"]?["similar"]?.boolValue == true)
        #expect(r["similar"]?.boolValue == true)
        #expect(r["matched_by"] == ["hash_color", "geometric_scene_overlap"])
    }

    @Test func testKeysMatchPython() throws {
        let (a, b) = pair()
        let r = try Compare.images(left: a, right: b, hashDistance: 12, histogramThreshold: 0.72,
                                   geometricThreshold: 0.55, geometricMaxFeatures: 4000, maxImageSide: 1600)
        let expected = [
            "geometric_scene_overlap", "geometric_scene_overlap.coverage_left", "geometric_scene_overlap.coverage_right",
            "geometric_scene_overlap.inlier_ratio", "geometric_scene_overlap.inliers",
            "geometric_scene_overlap.mutual_matches", "geometric_scene_overlap.score", "geometric_scene_overlap.similar",
            "hash_color", "hash_color.color_similarity", "hash_color.hash_distance", "hash_color.similar",
            "left", "left.geometric_features", "left.height", "left.orientation", "left.path", "left.width",
            "matched_by", "right", "right.geometric_features", "right.height", "right.orientation", "right.path", "right.width",
            "similar", "thresholds", "thresholds.geometric_scene_overlap", "thresholds.hash_distance",
            "thresholds.histogram_similarity", "timing_ms", "timing_ms.compare_geometric", "timing_ms.compare_hash_color",
            "timing_ms.extract_geometric", "timing_ms.extract_hash_color", "timing_ms.load_images",
        ]
        #expect(keyTree(r).filter { !$0.hasPrefix("timing_ms.") } == expected.filter { !$0.hasPrefix("timing_ms.") })
        #expect(Set(keyTree(r).filter { $0.hasPrefix("timing_ms.") }) == Set(expected.filter { $0.hasPrefix("timing_ms.") }))
        #expect(r["left"]?["orientation"]?.stringValue == "landscape")
        #expect(r["matched_by"] == ["geometric_scene_overlap"])
    }

    @Test func testScoresMatchPython() throws {
        let (a, b) = pair()
        let r = try Compare.images(left: a, right: b, hashDistance: 12, histogramThreshold: 0.72,
                                   geometricThreshold: 0.55, geometricMaxFeatures: 4000, maxImageSide: 1600)
        #expect(r["hash_color"]?["hash_distance"]?.intValue == 14)
        #expect(abs((r["hash_color"]?["color_similarity"]?.doubleValue ?? 0) - 0.9969) < 1e-3)
        #expect(r["hash_color"]?["similar"]?.boolValue == false)
        #expect(abs((r["geometric_scene_overlap"]?["score"]?.doubleValue ?? 0) - 1.0) < 2e-2)
        #expect(r["geometric_scene_overlap"]?["similar"]?.boolValue == true)
        #expect(r["left"]?["width"]?.intValue == 320)
        #expect(r["left"]?["height"]?.intValue == 240)
    }
}
