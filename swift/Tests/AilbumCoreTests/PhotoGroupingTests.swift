import Testing
@testable import AilbumCore

@Suite struct PhotoGroupingTests {
    private func photo(_ id: Int, story: Int? = 1, cluster: Int? = nil, quality: Double? = nil,
                       fav: Bool = false, auto: Bool = false, w: Int? = 300, h: Int? = 200, o: Int? = nil,
                       taken: String? = nil, title: String? = nil) -> Photo {
        try! AppModels.decode(Photo.self, .object([
            "id": .int(id), "path": .string("/p\(id).jpg"), "availability": .string("present"),
            "file_name": .string("p\(id).jpg"), "modified_at": .string("2026-07-01T10:00:00"),
            "scene_tags": .array([]), "object_tags": .array([]), "is_blurry": .bool(false),
            "auto_selected": .bool(auto), "face_count": .int(0), "people_count": .int(0),
            "closed_eyes_count": .int(0), "smiling_faces_count": .int(0), "people_names": .array([]),
            "favorite": .bool(fav),
            "story_id": story.map { .int($0) } ?? .null,
            "similar_cluster": cluster.map { .int($0) } ?? .null,
            "quality": quality.map { .double($0) } ?? .null,
            "width": w.map { .int($0) } ?? .null, "height": h.map { .int($0) } ?? .null,
            "orientation": o.map { .int($0) } ?? .null,
            "taken_at": taken.map { .string($0) } ?? .null,
            "story_title": title.map { .string($0) } ?? .null,
        ]))
    }

    private func story(_ s: String?, _ e: String?) -> Story {
        Story(id: 1, title: "t", started_at: s, ended_at: e, representative_image_id: nil, photo_count: 3, naming_model: nil)
    }

    @Test func testColumnCountBoundaries() {
        #expect(PhotoGrouping.columnCount(width: 1200) == 4)
        #expect(PhotoGrouping.columnCount(width: 1540) == 6)
        #expect(PhotoGrouping.columnCount(width: 1539.9) == 5)
        #expect(PhotoGrouping.columnCount(width: 1260) == 5)
        #expect(PhotoGrouping.columnCount(width: 980) == 4)
        #expect(PhotoGrouping.columnCount(width: 979) == 3)
        #expect(PhotoGrouping.columnCount(width: 720) == 3)
        #expect(PhotoGrouping.columnCount(width: 719) == 2)
        #expect(PhotoGrouping.columnCount(width: 0) == 2)
    }

    @Test func testDateLabel() {
        #expect(PhotoGrouping.dateLabel("2026-07-28T20:49:55").date == "28 июля 2026 г.")
        #expect(PhotoGrouping.dateLabel("2026-07-28T20:49:55").weekday == "вторник")
        #expect(PhotoGrouping.dateLabel("2026-01-05").date == "5 января 2026 г.")
        #expect(PhotoGrouping.dateLabel("2026-01-05").weekday == "понедельник")
        #expect(PhotoGrouping.dateLabel("Без даты").date == "Без даты")
        #expect(PhotoGrouping.dateLabel("Без даты").weekday == "")
    }

    @Test func testStoryPeriodLabel() {
        #expect(PhotoGrouping.storyPeriodLabel(story(nil, nil)) == "Время неизвестно")
        #expect(PhotoGrouping.storyPeriodLabel(story("garbage", nil)) == "Время неизвестно")
        #expect(PhotoGrouping.storyPeriodLabel(story("2026-07-28T09:05:00", nil)) == "28 июля 2026 г. \u{00B7} 09:05")
        #expect(PhotoGrouping.storyPeriodLabel(story("2026-07-28T09:05:00", "2026-07-28T20:49:55")) ==
                       "28 июля 2026 г. \u{00B7} 09:05\u{2013}20:49")
        #expect(PhotoGrouping.storyPeriodLabel(story("2026-07-28T09:05:00", "2026-07-30T01:00:00")) ==
                       "28 июля 2026 г. \u{2014} 30 июля 2026 г.")
        // the string's own zone is kept, not converted to the machine zone
        #expect(PhotoGrouping.storyPeriodLabel(story("2026-07-28T23:30:00+03:00", nil)) == "28 июля 2026 г. \u{00B7} 23:30")
    }

    @Test func testScoreRounding() {
        #expect(PhotoGrouping.score(photo(1, quality: 0.865)) == 87)
        #expect(PhotoGrouping.score(photo(1, quality: 0.5)) == 50)
        #expect(PhotoGrouping.score(photo(1, quality: 0.004)) == 0)
        #expect(PhotoGrouping.score(photo(1, quality: nil)) == nil)
    }

    @Test func testIsPortrait() {
        #expect(!(PhotoGrouping.isPortrait(photo(1, w: 300, h: 200))))
        #expect(PhotoGrouping.isPortrait(photo(1, w: 200, h: 300)))
        #expect(PhotoGrouping.isPortrait(photo(1, w: 300, h: 200, o: 6)))
        #expect(!(PhotoGrouping.isPortrait(photo(1, w: 200, h: 300, o: 8))))
        #expect(PhotoGrouping.isPortrait(photo(1, w: 200, h: 300, o: 3)))
        #expect(!(PhotoGrouping.isPortrait(photo(1, w: nil, h: 300))))
        #expect(!(PhotoGrouping.isPortrait(photo(1, w: 200, h: 200))))
    }

    @Test func testStackRepresentativeOrder() {
        #expect(PhotoGrouping.stackRepresentative([]) == nil)
        let a = photo(1, quality: 0.9), b = photo(2, quality: 0.5, auto: true)
        let c = photo(3, quality: 0.1, fav: true), d = photo(4, quality: 0.1, fav: true)
        #expect(PhotoGrouping.stackRepresentative([a, b, c, d])?.id == 3)  // favorite, stable on ties
        #expect(PhotoGrouping.stackRepresentative([a, b])?.id == 2)        // auto_selected beats quality
        #expect(PhotoGrouping.stackRepresentative([photo(5, quality: nil), photo(6, quality: 0)])?.id == 6)
        #expect(PhotoGrouping.stackRepresentative([photo(7, quality: 0.3), photo(8, quality: 0.3)])?.id == 7)
    }

    @Test func testSectionsGroupingStacksAndFallbackStory() {
        let photos = [
            photo(1, story: 1, cluster: 10, quality: 0.2),
            photo(2, story: 2, taken: "2026-07-02T08:00:00", title: "Лес"),
            photo(3, story: 1, cluster: 10, quality: 0.8),
            photo(4, story: 1, cluster: 11),
            photo(5, story: nil),
            photo(6, story: 2, taken: "2026-07-02T09:00:00"),
        ]
        let known = Story(id: 1, title: "Море", started_at: nil, ended_at: nil, representative_image_id: nil, photo_count: 9, naming_model: nil)
        let out = PhotoGrouping.sections(photos: photos, stories: [known], expandedSeries: [])
        #expect(out.map(\.key) == ["header-1", "header-2", "header-0"])
        #expect(out[0].count == 9)
        #expect(out[0].items.count == 2)
        guard case .stack(let key, let seriesKey, let members, let rep) = out[0].items[0] else { Issue.record("stack"); return }
        #expect(key == "stack-1:10"); #expect(seriesKey == "1:10")
        #expect(members.map(\.id) == [1, 3]); #expect(rep.id == 3)
        #expect(out[0].items[1] == .photo(key: "photo-4", photo: photos[3], series: nil))
        // fallback story built from the group
        #expect(out[1].story.title == "Лес")
        #expect(out[1].story.started_at == "2026-07-02T08:00:00")
        #expect(out[1].story.ended_at == "2026-07-02T09:00:00")
        #expect(out[1].story.representative_image_id == 2)
        #expect(out[1].count == 2)
        #expect(out[2].story.title == "Без сюжета")
        #expect(out[2].story.started_at == "2026-07-01T10:00:00")  // modified_at fallback
    }

    @Test func testDuplicateStoryIdLastWins() {
        let a = Story(id: 1, title: "A", started_at: nil, ended_at: nil, representative_image_id: nil, photo_count: 1, naming_model: nil)
        let b = Story(id: 1, title: "B", started_at: nil, ended_at: nil, representative_image_id: nil, photo_count: 2, naming_model: nil)
        let out = PhotoGrouping.sections(photos: [photo(1)], stories: [a, b], expandedSeries: [])
        #expect(out[0].story.title == "B")
    }

    @Test func testExpandedSeries() {
        let photos = [photo(1, cluster: 10), photo(2), photo(3, cluster: 10)]
        let out = PhotoGrouping.sections(photos: photos, stories: [], expandedSeries: ["1:10"])
        #expect(out[0].items == [
            .photo(key: "photo-1", photo: photos[0], series: SeriesInfo(key: "1:10", size: 2, isFirst: true)),
            .photo(key: "photo-3", photo: photos[2], series: SeriesInfo(key: "1:10", size: 2, isFirst: false)),
            .photo(key: "photo-2", photo: photos[1], series: nil),
        ])
    }
}
