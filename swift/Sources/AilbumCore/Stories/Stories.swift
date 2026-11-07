import Foundation

/// Port of `detect_stories` and its record builders (src/ailbum/stories.py).
public enum Stories {
    public static let algorithmVersion = 9

    static let sceneTitles: [String: String] = [
        "food": "За столом", "party": "Праздник", "ceremony": "Церемония",
        "performance": "Выступление", "portrait_session": "Фотосессия",
        "seaside_photo_session": "Фотосессия на берегу моря", "swimming": "Купание",
        "pool": "Фото у бассейна", "waterpark": "В аквапарке", "water_sports": "Водные развлечения",
        "restaurant": "В ресторане", "dinner": "Ужин", "hookah": "Отдых с кальяном",
        "sightseeing": "Осмотр достопримечательностей", "hotel": "Отдых в отеле",
        "hotel_lobby": "Фото в лобби отеля", "hotel_exterior": "Фото отеля снаружи",
        "beach": "У моря", "boat_trip": "Морская прогулка", "mountains": "В горах",
        "mountain_trip": "Поездка в горы", "evening_nature": "Вечерняя природа",
        "nature": "На природе", "city": "Городская прогулка", "transport": "В дороге",
        "architecture": "Архитектура", "diving": "Дайвинг", "night": "Вечер",
        "night_sky": "Ночное небо", "indoor": "В помещении",
    ]
    static let objectTitles: [String: String] = [
        "animal": "С животными", "food": "За столом", "vehicle": "В дороге",
    ]
    static let genericScenes: Set<String> = ["indoor", "night"]

    public static func detect(
        _ photos: [StoryPhoto], gapMinutes: Int = 120, continuityMinutes: Int = 360,
        maxDurationHours: Int = 12
    ) -> [StoryRecord] {
        if photos.isEmpty { return [] }
        var parsed: [String: Date?] = [:]
        for photo in photos { parsed[photo.photoId] = StoryBursts.parseTime(photo.takenAt) }
        func time(_ photo: StoryPhoto) -> Date? { parsed[photo.photoId] ?? nil }

        let ordered = photos.enumerated().sorted { a, b in
            let ta = time(a.element), tb = time(b.element)
            if (ta == nil) != (tb == nil) { return tb == nil }
            if let ta, let tb, ta != tb { return ta < tb }
            return a.offset < b.offset
        }.map(\.element)
        let timed = ordered.filter { time($0) != nil }
        let untimed = ordered.filter { time($0) == nil }

        var groups: [[StoryPhoto]] = []
        if !timed.isEmpty {
            var bursts = StoryBursts.build(timed, parsed: parsed)
            StoryBursts.attachVectors(&bursts)
            if bursts.contains(where: { $0.vector != nil }) {
                groups = StorySegmentation.segment(
                    bursts, continuityMinutes: continuityMinutes, maxDurationHours: maxDurationHours
                ).map { (range: (Int, Int)) -> [StoryPhoto] in bursts[range.0..<range.1].flatMap { $0.photos } }
            } else {
                groups = StorySegmentation.fallbackTimeGroups(
                    timed, parsed: parsed, gapMinutes: gapMinutes, continuityMinutes: continuityMinutes,
                    maxDurationHours: maxDurationHours)
            }
        }
        groups.append(contentsOf: untimed.map { [$0] })
        return storyRecords(groups, parsed)
    }

    static func storyRecords(_ groups: [[StoryPhoto]], _ parsed: [String: Date?]) -> [StoryRecord] {
        var stories: [StoryRecord] = []
        for (offset, members) in groups.enumerated() {
            let storyId = offset + 1
            let times = members.compactMap { parsed[$0.photoId] ?? nil }
            let sceneScores = labelScores(members, \.scenes)
            let objectScores = labelScores(members, \.objects)
            let scenes = rankedLabels(sceneScores)
            let objects = rankedLabels(objectScores)
            var best = 0
            for index in 1..<members.count {
                let a = members[index], b = members[best]
                // key: (not blurry, quality, -index); a later index never wins a tie
                let better: Bool
                if a.isBlurry != b.isBlurry { better = !a.isBlurry } else { better = a.quality > b.quality }
                if better { best = index }
            }
            let first = times.min()
            stories.append(
                StoryRecord(
                    storyId: storyId,
                    title: storyTitle(members, scenes, objects, first, sceneScores),
                    photoIds: members.map(\.photoId),
                    startedAt: first.map(StoryBursts.formatTime),
                    endedAt: times.max().map(StoryBursts.formatTime),
                    representativePhotoId: members[best].photoId,
                    sceneLabels: scenes, objectLabels: objects))
        }
        return stories
    }

    static func labelScores(_ photos: [StoryPhoto], _ attribute: KeyPath<StoryPhoto, [TagRecord]>) -> [String: Double] {
        var scores: [String: Double] = [:]
        for photo in photos {
            for tag in photo[keyPath: attribute] { scores[tag.label, default: 0] += max(0.0, tag.confidence) }
        }
        return scores
    }

    static func rankedLabels(_ scores: [String: Double]) -> [String] {
        scores.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key.unicodeScalars.lexicographicallyPrecedes(b.key.unicodeScalars)
        }.map(\.key)
    }

    static func storyTitle(
        _ photos: [StoryPhoto], _ scenes: [String], _ objects: [String], _ startedAt: Date?,
        _ sceneScores: [String: Double]
    ) -> String {
        let informative = scenes.filter { sceneTitles[$0] != nil && !genericScenes.contains($0) }
        if let primary = informative.first {
            if informative.count > 1, sceneScores[informative[1]]! >= sceneScores[primary]! * 0.7 {
                let secondary = sceneTitles[informative[1]]!
                return "\(sceneTitles[primary]!) · \(secondary.prefix(1).lowercased())\(secondary.dropFirst())"
            }
            return sceneTitles[primary]!
        }
        for label in objects { if let title = objectTitles[label] { return title } }
        if photos.contains(where: { !$0.people.isEmpty }) || objects.contains("people") {
            return "Совместный отдых"
        }
        for label in scenes { if let title = sceneTitles[label] { return title } }
        if let startedAt {
            let k = StoryBursts.timeKey(startedAt)
            func p(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
            return "Фотографии \(p(k.2)).\(p(k.1)), \(p(k.3)):\(p(k.4))"
        }
        return "Фотографии без даты"
    }
}
