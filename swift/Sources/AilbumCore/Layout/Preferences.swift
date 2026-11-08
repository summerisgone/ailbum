import Foundation

public enum Preferences {
    static let axes = ["faces", "closeups", "landscapes"]
    static let labels: [String: (String, String)] = [
        "faces": ("больше лиц", "меньше лиц"),
        "closeups": ("больше крупных планов", "меньше крупных планов"),
        "landscapes": ("больше пейзажей", "меньше пейзажей"),
    ]
    static let strength = 0.5
    static let closeupArea = 0.15
    static let maxPrompt = 500

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let patterns: [(String, NSRegularExpression)] = [
        ("faces", regex("лиц|люд|человек|портрет|семь|дет(?!ал)|друз|групп")),
        ("closeups", regex("крупн|портрет|детал")),
        (
            "landscapes",
            regex("пейзаж|природ|панорам|архитектур|город|море|моря|горы|гор(?![\\p{L}\\p{N}_])|общ[\\p{L}\\p{N}_]* план|вид(ы|ов)?(?![\\p{L}\\p{N}_])")
        ),
    ]
    private static let negative = regex("(^|\\s)(не|без|меньше|поменьше|убери[\\p{L}\\p{N}_]*|исключ[\\p{L}\\p{N}_]*|кроме|вместо)(\\s|$)")
    private static let clauses = regex("[,.;:!?\\n]+|\\s+(?:а|но|зато)\\s+")

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func split(_ s: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var last = 0
        for m in clauses.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    public static func parse(_ prompt: String) -> [String: Double] {
        // Python slices by code point, so truncate on unicode scalars.
        var text = String.UnicodeScalarView()
        text.append(contentsOf: prompt.lowercased().unicodeScalars.prefix(maxPrompt))
        var weights: [String: Double] = [:]
        for clause in split(String(text)) {
            let sign = matches(negative, clause) ? -1.0 : 1.0
            for (axis, pattern) in patterns where matches(pattern, clause) {
                weights[axis] = max(-1.0, min(1.0, (weights[axis] ?? 0.0) + sign))
            }
        }
        return weights.filter { $0.value != 0 }
    }

    public static func describe(_ weights: [String: Double]) -> [String] {
        axes.compactMap { axis in
            guard let w = weights[axis], let l = labels[axis] else { return nil }
            return w > 0 ? l.0 : l.1
        }
    }

    public static func features(_ photo: PhotoFacts) -> [String: Double] {
        let faces = photo.regions.filter { $0.kind == "face" }
        let people = faces.isEmpty
            ? photo.regions.filter { $0.kind == "person" || $0.kind == "face_background" } : faces
        let largest = faces.map { $0.bbox.w * $0.bbox.h }.max() ?? 0.0
        return [
            "faces": !faces.isEmpty ? 1.0 : !people.isEmpty ? 0.5 : 0.0,
            "closeups": min(1.0, largest / closeupArea),
            "landscapes": people.isEmpty ? 1.0 : 0.0,
        ]
    }

    public static func apply(_ photos: [PhotoFacts], _ weights: [String: Double]) -> [PhotoFacts] {
        if weights.isEmpty { return photos }
        return photos.map { photo in
            let values = features(photo)
            let bonus = strength * weights.reduce(0.0) { $0 + $1.value * (values[$1.key] ?? 0.0) }
            var p = photo
            p.rank = photo.rank + bonus
            return p
        }
    }
}
