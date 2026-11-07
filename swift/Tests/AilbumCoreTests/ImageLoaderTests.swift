import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import AilbumCore

private func tmpDir() -> String {
    let d = NSTemporaryDirectory() + "t3-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func writeJPEG(_ img: RGBImage, to path: String, props: [CFString: Any] = [:]) {
    var rgba = [UInt8](repeating: 255, count: img.width * img.height * 4)
    for i in 0..<(img.width * img.height) {
        for c in 0..<3 { rgba[i * 4 + c] = img.pixels[i * 3 + c] }
    }
    let ctx = CGContext(data: &rgba, width: img.width, height: img.height, bitsPerComponent: 8,
                        bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let cg = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.jpeg.identifier as CFString, 1, nil)!
    var p = props
    p[kCGImageDestinationLossyCompressionQuality] = 1.0
    CGImageDestinationAddImage(dest, cg, p as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

@Suite struct ImageLoaderTests {
    @Test func testOrientation6() throws {
        let d = tmpDir()
        var px = [UInt8](repeating: 0, count: 4 * 2 * 3)
        px[0] = 255 // top-left red
        let path = d + "/o.jpg"
        writeJPEG(RGBImage(width: 4, height: 2, pixels: px), to: path,
                  props: [kCGImagePropertyOrientation: 6])
        let img = try ImageLoader.load(path: path)
        #expect(img.width == 2 && img.height == 4)
        let tr = Int(img.pixels[(0 * 2 + 1) * 3])
        let tl = Int(img.pixels[0])
        let bl = Int(img.pixels[(3 * 2 + 0) * 3])
        #expect(tr > 100 && tr > tl + 50 && tr > bl + 50)
    }

    @Test func testDecodeGarbage() throws {
        let d = tmpDir()
        try Data("nope".utf8).write(to: URL(fileURLWithPath: d + "/x.jpg"))
        #expect(throws: AilbumError.self) { try ImageLoader.load(path: d + "/x.jpg") }
        do { _ = try ImageLoader.load(path: d + "/x.jpg") } catch let e as AilbumError {
            if case .decode = e {} else { Issue.record("wrong case \(e)") }
        }
    }

    @Test func testDiscoverSuffixes() throws {
        let d = tmpDir()
        try FileManager.default.createDirectory(atPath: d + "/sub", withIntermediateDirectories: true)
        for n in ["a.JPG", "b.webp", "c.txt", "sub/d.tiff"] {
            FileManager.default.createFile(atPath: d + "/" + n, contents: Data())
        }
        #expect(ImageLoader.discover(root: d, recursive: false) == [d + "/a.JPG", d + "/b.webp"])
        #expect(ImageLoader.discover(root: d, recursive: true) == [d + "/a.JPG", d + "/b.webp", d + "/sub/d.tiff"])
    }

    @Test func testAreaParity() {
        let px = (0..<72).map { UInt8(($0 * 37) % 256) }
        let out = Resize.area(RGBImage(width: 6, height: 4, pixels: px), width: 3, height: 2)
        let golden: [UInt8] = [69, 106, 143, 163, 72, 109, 129, 166, 75, 121, 158, 131, 87, 124, 161, 181, 90, 127]
        #expect(out.width == 3 && out.height == 2)
        #expect(out.pixels == golden)
    }

    @Test func testRoundScale() {
        let img = RGBImage(width: 1001, height: 500, pixels: [UInt8](repeating: 10, count: 1001 * 500 * 3))
        let (r, s) = Resize.forAnalysis(img, maxSide: 500)
        #expect(r.width == 500 && r.height == 250)
        #expect(s == 500.0 / 1001.0)
        #expect(r.pixels.allSatisfy { $0 == 10 })
    }

    @Test func testNoUpscale() {
        let img = RGBImage(width: 8, height: 6, pixels: [UInt8](repeating: 1, count: 8 * 6 * 3))
        let (r, s) = Resize.forAnalysis(img, maxSide: 1600)
        #expect(r == img && s == 1.0)
    }

    @Test func testTakenAtExif() throws {
        let d = tmpDir()
        let path = d + "/e.jpg"
        let img = RGBImage(width: 4, height: 4, pixels: [UInt8](repeating: 100, count: 48))
        writeJPEG(img, to: path, props: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:20:30"]])
        let date = try #require(ImageLoader.takenAt(path: path))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2024, 5, 1, 10, 20, 30])
    }

    @Test func testTakenAtFallback() throws {
        let d = tmpDir()
        let path = d + "/n.jpg"
        let img = RGBImage(width: 4, height: 4, pixels: [UInt8](repeating: 100, count: 48))
        writeJPEG(img, to: path)
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        let date = try #require(ImageLoader.takenAt(path: path))
        #expect(abs(date.timeIntervalSince(mtime)) < 1)
    }
}
