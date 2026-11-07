import Foundation

/// Port of `_Burst` (src/ailbum/stories.py).
public struct StoryBurst {
    public var photos: [StoryPhoto]
    public var startedAt: Date
    public var endedAt: Date
    public var vector: [Double]?
    public var imageVector: [Double]?
    public var semanticVector: [Double]?
    public var people: Set<String>
    public var faceRate: Double

    public init(
        photos: [StoryPhoto], startedAt: Date, endedAt: Date, vector: [Double]? = nil,
        imageVector: [Double]? = nil, semanticVector: [Double]? = nil,
        people: Set<String> = [], faceRate: Double = 0.0
    ) {
        self.photos = photos
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.vector = vector
        self.imageVector = imageVector
        self.semanticVector = semanticVector
        self.people = people
        self.faceRate = faceRate
    }
}

public enum StoryBursts {
    static let burstMinutes = 1.0
    static let sceneVectorWeight = 0.10
    static let objectVectorWeight = 0.10
    static let peopleVectorWeight = 0.15
    static let facePresenceWeight = 0.10

    public static func build(_ photos: [StoryPhoto], parsed: [String: Date?]) -> [StoryBurst] {
        var bursts: [StoryBurst] = []
        for photo in photos {
            guard let entry = parsed[photo.photoId], let takenAt = entry else {
                preconditionFailure("photo \(photo.photoId) has no parsed time")
            }
            if let last = bursts.last, takenAt.timeIntervalSince(last.endedAt) / 60 <= burstMinutes {
                bursts[bursts.count - 1].photos.append(photo)
                bursts[bursts.count - 1].endedAt = takenAt
            } else {
                bursts.append(StoryBurst(photos: [photo], startedAt: takenAt, endedAt: takenAt))
            }
        }
        return bursts
    }

    public static func attachVectors(_ bursts: inout [StoryBurst]) {
        var sceneSet = Set<String>(), objectSet = Set<String>(), peopleSet = Set<String>()
        var embeddingDim = 0
        for burst in bursts {
            for photo in burst.photos {
                for tag in photo.scenes { sceneSet.insert(tag.label) }
                for tag in photo.objects { objectSet.insert(tag.label) }
                peopleSet.formUnion(photo.people)
                if let e = photo.embedding { embeddingDim = max(embeddingDim, e.count) }
            }
        }
        let sceneLabels = sceneSet.sorted(), objectLabels = objectSet.sorted()
        let peopleLabels = peopleSet.sorted()
        let sceneIndex = Dictionary(uniqueKeysWithValues: sceneLabels.enumerated().map { ($1, $0) })
        let objectIndex = Dictionary(uniqueKeysWithValues: objectLabels.enumerated().map { ($1, $0) })
        let peopleIndex = Dictionary(uniqueKeysWithValues: peopleLabels.enumerated().map { ($1, $0) })

        for i in bursts.indices {
            let photos = bursts[i].photos
            let imageVectors: [[Double]] = photos.compactMap { photo in
                guard let e = photo.embedding, !e.isEmpty, e.count == embeddingDim else { return nil }
                return e.map { Double($0) }
            }
            var imageVector: [Double]?
            if !imageVectors.isEmpty {
                var mean = [Double](repeating: 0, count: embeddingDim)
                for v in imageVectors { for k in 0..<embeddingDim { mean[k] += v[k] } }
                let n = Double(imageVectors.count)
                imageVector = normalized(mean.map { $0 / n })
            }
            var sceneVector = [Double](repeating: 0, count: sceneLabels.count)
            var objectVector = [Double](repeating: 0, count: objectLabels.count)
            var peopleVector = [Double](repeating: 0, count: peopleLabels.count)
            var people = Set<String>()
            for photo in photos {
                for tag in photo.scenes { sceneVector[sceneIndex[tag.label]!] += max(0.0, tag.confidence) }
                for tag in photo.objects { objectVector[objectIndex[tag.label]!] += max(0.0, tag.confidence) }
                for person in photo.people {
                    peopleVector[peopleIndex[person]!] = 1.0
                    people.insert(person)
                }
            }
            let divisor = Double(max(1, photos.count))
            sceneVector = sceneVector.map { $0 / divisor }
            objectVector = objectVector.map { $0 / divisor }
            bursts[i].people = people
            bursts[i].faceRate = Double(photos.filter { !$0.people.isEmpty }.count) / divisor
            bursts[i].imageVector = imageVector
            bursts[i].semanticVector = normalized(normalized(sceneVector) + normalized(objectVector))
            let hasContent = !imageVectors.isEmpty || sceneVector.contains { $0 != 0 }
                || objectVector.contains { $0 != 0 } || !people.isEmpty
            if !hasContent { continue }
            var components: [Double] = imageVector ?? [Double](repeating: 0, count: embeddingDim)
            components += normalized(sceneVector).map { sceneVectorWeight * $0 }
            components += normalized(objectVector).map { objectVectorWeight * $0 }
            components += normalized(peopleVector).map { peopleVectorWeight * $0 }
            components.append(facePresenceWeight * bursts[i].faceRate)
            bursts[i].vector = normalized(components)
        }

        // Failed/unsupported files inherit only the closest content representation.
        let available = bursts.indices.filter { bursts[$0].vector != nil }
        for i in bursts.indices where bursts[i].vector == nil && !available.isEmpty {
            var closest = available[0]
            for candidate in available where abs(candidate - i) < abs(closest - i) { closest = candidate }
            bursts[i].vector = bursts[closest].vector
            bursts[i].imageVector = bursts[closest].imageVector
            bursts[i].semanticVector = bursts[closest].semanticVector
        }
    }

    static func normalized(_ vector: [Double]) -> [Double] {
        var sum = 0.0
        for v in vector { sum += v * v }
        let norm = sum.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    static func meanVector(_ vectors: [[Double]?]) -> [Double]? {
        let present = vectors.compactMap { $0 }.filter { !$0.isEmpty }
        guard let first = present.first else { return nil }
        var sum = [Double](repeating: 0, count: first.count)
        for v in present { for k in 0..<sum.count { sum[k] += v[k] } }
        return normalized(sum)
    }

    public static func vectorDistance(_ a: [Double]?, _ b: [Double]?) -> Double {
        guard let a, let b else { return (a == nil && b == nil) ? 0.0 : 1.0 }
        var aa = 0.0, bb = 0.0, ab = 0.0
        for k in 0..<min(a.count, b.count) { ab += a[k] * b[k] }
        for v in a { aa += v * v }
        for v in b { bb += v * v }
        let ln = aa.squareRoot(), rn = bb.squareRoot()
        if ln == 0 && rn == 0 { return 0.0 }
        if ln == 0 || rn == 0 { return 1.0 }
        return max(0.0, min(2.0, 1.0 - ab / ln / rn))
    }

    public static func parseTime(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        // datetime.fromisoformat: date, optional [T| ]time, optional offset (dropped).
        var s = Substring(value.replacingOccurrences(of: "Z", with: "+00:00"))
        let dateParts = s.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard s.count >= 10, dateParts.count == 3, dateParts[0].count == 4, dateParts[1].count == 2,
            dateParts[2].count == 2, let y = Int(dateParts[0]), let mo = Int(dateParts[1]),
            let d = Int(dateParts[2])
        else { return nil }
        s = s.dropFirst(10)
        var h = 0, mi = 0, sec = 0, micro = 0
        if !s.isEmpty {
            guard s.first == "T" || s.first == " " else { return nil }
            s = s.dropFirst()
            if let off = s.firstIndex(where: { $0 == "+" || $0 == "-" }) {
                let tz = s[off...].dropFirst().filter { $0 != ":" }
                guard !tz.isEmpty, tz.count <= 6 || tz.contains("."), tz.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
                s = s[..<off]
            }
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count), parts[0].count == 2, parts[1].count == 2,
                let hh = Int(parts[0]), let mm = Int(parts[1])
            else { return nil }
            h = hh; mi = mm
            if parts.count == 3 {
                let sp = parts[2].split(separator: ".", omittingEmptySubsequences: false)
                guard sp.count <= 2, sp[0].count == 2, let ss = Int(sp[0]) else { return nil }
                sec = ss
                if sp.count == 2 {
                    guard (1...6).contains(sp[1].count), sp[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                        let f = Int(sp[1])
                    else { return nil }
                    micro = f * Int(pow(10.0, Double(6 - sp[1].count)))
                }
            }
        }
        guard (1...12).contains(mo), d >= 1, h < 24, mi < 60, sec < 60, y >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)
        guard let date = calendar.date(from: comps),
            calendar.dateComponents([.year, .month, .day], from: date).day == d
        else { return nil }
        return date.addingTimeInterval(Double(micro) / 1_000_000)
    }

    /// `_time_key`: nil sorts last.
    static func timeKey(_ value: Date?) -> (Int, Int, Int, Int, Int, Int, Int) {
        guard let value else { return (9999, 12, 31, 23, 59, 59, 999999) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        let micro = Int(((value.timeIntervalSinceReferenceDate - value.timeIntervalSinceReferenceDate.rounded(.down)) * 1_000_000).rounded())
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, micro)
    }

    /// `_format_time`: datetime.isoformat() of a naive datetime.
    static func formatTime(_ value: Date) -> String {
        let k = timeKey(value)
        func p(_ n: Int, _ w: Int) -> String { String(repeating: "0", count: max(0, w - String(n).count)) + String(n) }
        var out = "\(p(k.0, 4))-\(p(k.1, 2))-\(p(k.2, 2))T\(p(k.3, 2)):\(p(k.4, 2)):\(p(k.5, 2))"
        if k.6 != 0 { out += ".\(p(k.6, 6))" }
        return out
    }

    public static func distanceKm(_ a: StoryPhoto, _ b: StoryPhoto) -> Double? {
        guard let aLat = a.gpsLatitude, let aLon = a.gpsLongitude,
            let bLat = b.gpsLatitude, let bLon = b.gpsLongitude,
            !(aLat == 0.0 && aLon == 0.0), !(bLat == 0.0 && bLon == 0.0)
        else { return nil }
        let radius = 6371.0
        let lat1 = aLat * .pi / 180, lat2 = bLat * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (bLon - aLon) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return radius * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
    }

    static func distanceKmBetweenBursts(_ left: StoryBurst, _ right: StoryBurst) -> Double? {
        var best: Double?
        for l in left.photos {
            for r in right.photos {
                if let d = distanceKm(l, r), best == nil || d < best! { best = d }
            }
        }
        return best
    }

    static func largeGeographicJump(_ left: StoryBurst, _ right: StoryBurst, gap: Double) -> Bool {
        guard gap > 15, let d = distanceKmBetweenBursts(left, right) else { return false }
        return d > 25
    }

    static func visualVector(_ burst: StoryBurst) -> [Double]? { burst.imageVector ?? burst.vector }
}
