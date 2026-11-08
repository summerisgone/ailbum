import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Testing
@testable import AilbumCore

struct MetadataTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meta-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJPEG(_ url: URL, properties: [CFString: Any]? = nil) throws {
        let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 20 / 255, green: 100 / 255, blue: 180 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, properties as CFDictionary?)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func writeImageWithExif(_ url: URL) throws {
        try writeJPEG(url, properties: [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Ailbum Camera",
                kCGImagePropertyTIFFModel: "Test Model",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:08:07 12:34:56"],
            kCGImagePropertyOrientation: 6,
        ])
    }

    @Test func testCollectsPathsHashAndExif() throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let path = source.appendingPathComponent("sample.jpg")
        try writeImageWithExif(path)

        let metadata = try Metadata.collect(path: path.path, source: source.path)

        #expect(metadata.path == URL(fileURLWithPath: path.path).path.withRealPath)
        #expect(metadata.relativePath == "sample.jpg")
        #expect(metadata.sha256.count == 64)
        #expect(metadata.cameraMake == "Ailbum Camera")
        #expect(metadata.cameraModel == "Test Model")
        #expect(metadata.takenAt == "2026-08-07T12:34:56")
        #expect(metadata.orientation == 6)
        #expect(metadata.width == 120)
        #expect(metadata.height == 80)
        #expect(metadata.imageFormat == "JPEG")
    }

    @Test func testUsesCameraFilenameTimestampWhenExifIsMissing() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("20260731_184622.jpg")
        try writeJPEG(path)

        let metadata = try Metadata.collect(path: path.path, source: dir.path)

        #expect(metadata.takenAt == "2026-07-31T18:46:22")
    }

    @Test func testFilenameTimestampSurvivesImageExtractionError() throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("20260804_183527.jpg")
        try Data("not an image".utf8).write(to: path)

        let metadata = try Metadata.collect(path: path.path, source: dir.path)

        #expect(metadata.takenAt == "2026-08-04T18:35:27")
        #expect(metadata.extractionError != nil)
    }

    @Test func testZeroZeroGpsIsTreatedAsMissing() {
        let (latitude, longitude, _) = Metadata.gpsCoordinates(
            ["GPSLatitude": [0, 0, 0], "GPSLongitude": [0, 0, 0]])

        #expect(latitude == nil)
        #expect(longitude == nil)
    }

    @Test func testUnicodePath() throws {
        let dir = try tempDir()
        let folder = dir.appendingPathComponent("Фото")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("кадр.jpg")
        try writeJPEG(path)

        let metadata = try Metadata.collect(path: path.path, source: dir.path)

        #expect(metadata.relativePath == "Фото/кадр.jpg")
        #expect(metadata.fileName == "кадр.jpg")
        #expect(metadata.extractionError == nil)
        #expect(metadata.width == 120)
    }
}

private extension String {
    var withRealPath: String {
        guard let r = realpath(self, nil) else { return self }
        defer { free(r) }
        return String(cString: r)
    }
}
