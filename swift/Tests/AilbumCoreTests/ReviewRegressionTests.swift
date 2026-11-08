import Foundation
import Testing
@testable import AilbumCore

@Suite struct ReviewRegressionTests {
    @Test func nonFiniteFloatsUsePythonTokensAndParseBack() throws {
        let text = AnalysisStore.json(.array([.double(.nan), .double(.infinity), .double(-.infinity), .double(1.5)]))
        #expect(text == "[NaN,Infinity,-Infinity,1.5]")
        let parsed = try JSONValue.parse(text)
        #expect(parsed[0]?.doubleValue?.isNaN == true)
        #expect(parsed[1]?.doubleValue == .infinity)
        #expect(parsed[2]?.doubleValue == -.infinity)
    }

    @Test func indexingExifWithNaNDoesNotFail() throws {
        let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        let item = ImageMetadata(
            path: dir + "/src/a.jpg", sourceRoot: dir + "/src", relativePath: "a.jpg", fileName: "a.jpg",
            extension: ".jpg", fileSizeBytes: 1, modifiedAt: "2024-05-01T10:00:00", sha256: "s",
            exif: ["gps": ["GPSImgDirection": .double(.nan)]])
        let counts = try Catalog.indexMetadata(database: dir + "/c.sqlite3", source: dir + "/src", metadata: [item])
        #expect(counts["images"]?.intValue == 1)
        let image = try CatalogQueries.getImage(database: dir + "/c.sqlite3", imageId: 1)
        #expect(image["exif"]?["gps"]?["GPSImgDirection"]?.doubleValue?.isNaN == true)
    }

    @Test func segmentOfNoBurstsIsEmpty() {
        #expect(StorySegmentation.segment([], continuityMinutes: 360, maxDurationHours: 12).isEmpty)
    }

    @Test func filenameTimestampWithNonAsciiDigitsDoesNotTrap() {
        // Python's \d and int() accept Unicode decimal digits.
        #expect(Metadata.filenameTakenAt("IMG_20٢٣٠١٠١_١٢٣٠٤٥.jpg") == "2023-01-01T12:30:45")
        #expect(Metadata.filenameTakenAt("IMG_20230101_123045.jpg") == "2023-01-01T12:30:45")
    }
}
