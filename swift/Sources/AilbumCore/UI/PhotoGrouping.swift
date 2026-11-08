import Foundation

public struct SeriesInfo: Equatable, Sendable {
    public var key: String
    public var size: Int
    public var isFirst: Bool
}

public enum GridItem: Equatable, Sendable {
    case photo(key: String, photo: Photo, series: SeriesInfo?)
    case stack(key: String, seriesKey: String, photos: [Photo], representative: Photo)
}

/// One story header followed by its photo/stack items (not yet split into rows by column count).
public struct GridSection: Equatable, Sendable {
    public var key: String
    public var story: Story
    public var count: Int
    public var items: [GridItem]
}

/// Port of the helpers in desktop/src/App.tsx (lines 52-135) and the grouping in VirtualPhotoGrid.
public enum PhotoGrouping {
    private static let noDate = "\u{0411}\u{0435}\u{0437} \u{0434}\u{0430}\u{0442}\u{044B}"
    private static let unknownTime = "\u{0412}\u{0440}\u{0435}\u{043C}\u{044F} \u{043D}\u{0435}\u{0438}\u{0437}\u{0432}\u{0435}\u{0441}\u{0442}\u{043D}\u{043E}"
    private static let noStory = "\u{0411}\u{0435}\u{0437} \u{0441}\u{044E}\u{0436}\u{0435}\u{0442}\u{0430}"

    private static var gmt: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = gmt
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = pattern
        return f
    }

    /// Wall-clock components of an ISO-like string; the string's own offset is kept as `offset` seconds.
    private struct Stamp { var wall: Date; var offset: Int }

    private static func parse(_ value: String) -> Stamp? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: value).map { String(value[$0]) }
        }
        var c = DateComponents()
        c.year = Int(group(1)!); c.month = Int(group(2)!); c.day = Int(group(3)!)
        c.hour = group(4).flatMap { Int($0) } ?? 0
        c.minute = group(5).flatMap { Int($0) } ?? 0
        c.second = group(6).flatMap { Int($0) } ?? 0
        guard (1...12).contains(c.month!), (1...31).contains(c.day!), c.hour! < 24, c.minute! < 60, c.second! < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = gmt
        guard let wall = cal.date(from: c), cal.dateComponents([.month, .day], from: wall).day == c.day else { return nil }
        var offset = 0
        if let z = group(7), z != "Z" {
            let digits = z.dropFirst().replacingOccurrences(of: ":", with: "")
            offset = (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60) * (z.hasPrefix("-") ? -1 : 1)
        }
        return Stamp(wall: wall, offset: offset)
    }

    /// DAY_FORMAT + WEEKDAY_FORMAT (ru-RU) of a "yyyy-MM-dd" date; "Без даты" is returned as date with empty weekday.
    public static func dateLabel(_ value: String) -> (date: String, weekday: String) {
        if value == noDate { return (value, "") }
        guard let stamp = parse(String(value.prefix(10))) else { return (value, "") }
        return (formatter("d MMMM y '\u{0433}'.").string(from: stamp.wall), formatter("EEEE").string(from: stamp.wall))
    }

    public static func storyPeriodLabel(_ story: Story) -> String {
        guard let startedAt = story.started_at, !startedAt.isEmpty else { return unknownTime }
        let endedAt = (story.ended_at?.isEmpty ?? true) ? startedAt : story.ended_at!
        guard let start = parse(startedAt), let end = parse(endedAt) else { return unknownTime }
        let day = formatter("d MMMM y '\u{0433}'.")
        let time = formatter("HH:mm")
        let dayKey = formatter("y-M-d")
        if dayKey.string(from: start.wall) == dayKey.string(from: end.wall) {
            let startInstant = start.wall.timeIntervalSince1970 - Double(start.offset)
            let endInstant = end.wall.timeIntervalSince1970 - Double(end.offset)
            let times = startInstant == endInstant
                ? time.string(from: start.wall)
                : "\(time.string(from: start.wall))\u{2013}\(time.string(from: end.wall))"
            return "\(day.string(from: start.wall)) \u{00B7} \(times)"
        }
        return "\(day.string(from: start.wall)) \u{2014} \(day.string(from: end.wall))"
    }

    /// Math.round(quality * 100); nil when quality is nil (TS: null).
    public static func score(_ photo: Photo) -> Double? {
        guard let q = photo.quality else { return nil }
        return (q * 100 + 0.5).rounded(.down)
    }

    public static func isPortrait(_ photo: Photo) -> Bool {
        guard let w = photo.width, let h = photo.height else { return false }
        let swaps = [5, 6, 7, 8].contains(photo.orientation ?? 1)
        return (swaps ? w : h) > (swaps ? h : w)
    }

    /// First element of a stable sort: favorite, then auto_selected, then quality descending (nil = -1).
    public static func stackRepresentative(_ photos: [Photo]) -> Photo? {
        func before(_ l: Photo, _ r: Photo) -> Bool {
            if l.favorite != r.favorite { return l.favorite }
            if l.auto_selected != r.auto_selected { return l.auto_selected }
            return (l.quality ?? -1) > (r.quality ?? -1)
        }
        guard var best = photos.first else { return nil }
        for p in photos.dropFirst() where before(p, best) { best = p }
        return best
    }

    public static func columnCount(width: Double) -> Int {
        if width >= 1540 { return 6 }
        if width >= 1260 { return 5 }
        if width >= 980 { return 4 }
        if width >= 720 { return 3 }
        return 2
    }

    /// Calendar day key of a photo: first 10 chars of taken_at, else modified_at, else "Без даты".
    public static func dateOf(_ photo: Photo) -> String {
        let v = (photo.taken_at?.isEmpty ?? true) ? photo.modified_at : photo.taken_at!
        return String((v.isEmpty ? noDate : v).prefix(10))
    }

    private static func firstNonEmpty(_ a: String?, _ b: String) -> String? {
        if let a, !a.isEmpty { return a }
        return b.isEmpty ? nil : b
    }

    public static func sections(photos: [Photo], stories: [Story], expandedSeries: Set<String>) -> [GridSection] {
        var storyById: [Int: Story] = [:]
        for s in stories { storyById[s.id] = s }
        var order: [Int] = []
        var groups: [Int: [Photo]] = [:]
        for photo in photos {
            let id = photo.story_id ?? 0
            if groups[id] == nil { order.append(id); groups[id] = [photo] } else { groups[id]!.append(photo) }
        }
        var result: [GridSection] = []
        for storyId in order {
            let items = groups[storyId]!
            let first = items[0], last = items[items.count - 1]
            let story = storyById[storyId] ?? Story(
                id: storyId,
                title: (first.story_title?.isEmpty ?? true) ? noStory : first.story_title!,
                started_at: firstNonEmpty(first.taken_at, first.modified_at),
                ended_at: firstNonEmpty(last.taken_at, last.modified_at),
                representative_image_id: first.id,
                photo_count: items.count,
                naming_model: nil)

            var series: [Int: [Photo]] = [:]
            for photo in items {
                guard let c = photo.similar_cluster else { continue }
                series[c, default: []].append(photo)
            }
            var gridItems: [GridItem] = []
            var emitted = Set<Int>()
            for photo in items {
                guard let cluster = photo.similar_cluster, let members = series[cluster], members.count >= 2 else {
                    gridItems.append(.photo(key: "photo-\(photo.id)", photo: photo, series: nil))
                    continue
                }
                if !emitted.insert(cluster).inserted { continue }
                let seriesKey = "\(storyId):\(cluster)"
                if expandedSeries.contains(seriesKey) {
                    for (i, member) in members.enumerated() {
                        gridItems.append(.photo(key: "photo-\(member.id)", photo: member,
                                                series: SeriesInfo(key: seriesKey, size: members.count, isFirst: i == 0)))
                    }
                } else {
                    gridItems.append(.stack(key: "stack-\(seriesKey)", seriesKey: seriesKey, photos: members,
                                            representative: stackRepresentative(members)!))
                }
            }
            result.append(GridSection(key: "header-\(storyId)", story: story, count: story.photo_count, items: gridItems))
        }
        return result
    }
}
