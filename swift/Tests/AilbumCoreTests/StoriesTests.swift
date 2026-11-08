import Foundation
import Testing

@testable import AilbumCore

private func photo(
    _ id: String, _ at: String, embedding: [Float]? = nil, scenes: [(String, Double)] = [],
    latitude: Double? = nil, longitude: Double? = nil
) -> StoryPhoto {
    StoryPhoto(
        photoId: id, takenAt: at, gpsLatitude: latitude, gpsLongitude: longitude,
        scenes: scenes.map { TagRecord(label: $0.0, confidence: $0.1) }, embedding: embedding,
        quality: 0.8)
}

private func detect(_ photos: [StoryPhoto]) -> [StoryRecord] {
    Stories.detect(photos, gapMinutes: 120, continuityMinutes: 360, maxDurationHours: 12)
}

@Suite struct StoriesTests {
    @Test func emptyInput() {
        #expect(detect([]) == [])
        #expect(Stories.algorithmVersion == 9)
    }

    @Test func sharpVisualChangeSplitsNearbyPhotos() {
        let stories = detect([
            photo("inside-1", "2026-08-07T10:00:00", embedding: [1, 0, 0, 0]),
            photo("inside-2", "2026-08-07T10:02:00", embedding: [0.99, 0.01, 0, 0]),
            photo("outside-1", "2026-08-07T10:12:00", embedding: [0, 1, 0, 0]),
            photo("outside-2", "2026-08-07T10:14:00", embedding: [0.01, 0.99, 0, 0]),
        ])
        #expect(stories.map(\.photoIds) == [["inside-1", "inside-2"], ["outside-1", "outside-2"]])
    }

    @Test func sameVisualActivityBridgesLongPause() {
        let stories = detect([
            photo("morning", "2026-08-07T09:00:00", embedding: [1, 0, 0]),
            photo("afternoon", "2026-08-07T12:00:00", embedding: [1, 0, 0]),
        ])
        #expect(stories.count == 1)
    }

    @Test func singleVisualOutlierDoesNotFragmentASequence() {
        let stories = detect([
            photo("a1", "2026-08-07T10:00:00", embedding: [1, 0, 0]),
            photo("a2", "2026-08-07T10:02:00", embedding: [1, 0, 0]),
            photo("outlier", "2026-08-07T10:04:00", embedding: [0, 1, 0]),
            photo("a3", "2026-08-07T10:06:00", embedding: [1, 0, 0]),
            photo("a4", "2026-08-07T10:08:00", embedding: [1, 0, 0]),
        ])
        #expect(stories.count == 1)
    }

    @Test func unreadablePhotoInheritsTemporalContext() {
        let stories = detect([
            photo("first", "2026-08-07T10:00:00", embedding: [1, 0, 0]),
            photo("unreadable", "2026-08-07T10:02:00"),
            photo("last", "2026-08-07T10:04:00", embedding: [1, 0, 0]),
        ])
        #expect(stories.count == 1)
        #expect(stories[0].photoIds == ["first", "unreadable", "last"])
    }

    @Test func labelNamesDoNotControlGrouping() {
        let stories = detect([
            photo("first", "2026-08-07T10:00:00", embedding: [1, 0, 0], scenes: [("arbitrary-a", 1.0)]),
            photo("second", "2026-08-07T10:02:00", embedding: [1, 0, 0], scenes: [("arbitrary-b", 1.0)]),
        ])
        #expect(stories.count == 1)
    }

    @Test func largeGeographicJumpSplitsClosePhotos() {
        let stories = detect([
            photo("home", "2026-08-07T10:00:00", embedding: [1, 0], latitude: 56.8389, longitude: 60.6057),
            photo("away", "2026-08-07T10:45:00", embedding: [1, 0], latitude: 55.7558, longitude: 37.6173),
        ])
        #expect(stories.map(\.photoIds) == [["home"], ["away"]])
    }

    @Test func continuityLimitForcesANewStory() {
        let stories = detect([
            photo("first", "2026-08-07T10:00:00", embedding: [1, 0]),
            photo("second", "2026-08-07T17:00:00", embedding: [1, 0]),
        ])
        #expect(stories.map(\.photoIds) == [["first"], ["second"]])
    }

    @Test func mixedTimezoneMetadataUsesLocalCameraTime() {
        let stories = detect([
            photo("phone", "2026-07-30T09:41:00+03:00", embedding: [1, 0]),
            photo("camera", "2026-07-30T10:00:00", embedding: [1, 0]),
        ])
        #expect(stories.count == 1)
        #expect(stories[0].photoIds == ["phone", "camera"])
    }

    @Test func ruleTitleIsOnlyATopLabelFallback() {
        let story = detect([
            photo("hookah", "2026-08-03T21:40:00", embedding: [1, 0], scenes: [("hookah", 0.99), ("performance", 0.5)])
        ])[0]
        #expect(story.title == "Отдых с кальяном")
    }

    @Test func storyWithoutSemanticsGetsDatedFallbackNotEvent() {
        let story = detect([photo("photo", "2026-08-03T12:34:00", embedding: [1, 0])])[0]
        #expect(story.title == "Фотографии 03.08, 12:34")
    }
}
