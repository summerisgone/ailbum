import Foundation

public struct AnnotatedStory: Equatable {
    public var title: String
    public var fileNames: [String]
    public init(title: String, fileNames: [String]) {
        self.title = title
        self.fileNames = fileNames
    }
}

public enum StoryEvaluation {
    static let videoExtensions: Set<String> = [".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v"]

    /// Mirrors Python `str.splitlines`.
    private static func splitLines(_ text: String) -> [String] {
        let breaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]
        var lines: [String] = []
        var cur = String.UnicodeScalarView()
        var prevCR = false
        for s in text.unicodeScalars {
            if prevCR {
                prevCR = false
                if s.value == 0x0A { continue }
            }
            if breaks.contains(s.value) {
                lines.append(String(cur))
                cur = String.UnicodeScalarView()
                prevCR = s.value == 0x0D
            } else {
                cur.append(s)
            }
        }
        if !cur.isEmpty { lines.append(String(cur)) }
        return lines
    }

    private static func strip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripChar(_ s: String, _ c: Character) -> String {
        var v = Substring(s)
        while v.first == c { v = v.dropFirst() }
        while v.last == c { v = v.dropLast() }
        return String(v)
    }

    /// Python `Path(candidate).suffix.casefold()`.
    private static func suffix(_ candidate: String) -> String {
        let name = candidate.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return "" }
        return String(name[dot...]).lowercased()
    }

    private static func dedup(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    public static func parseAnnotations(path: String) throws -> [AnnotatedStory] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var stories: [AnnotatedStory] = []
        var title: String?
        var names: [String] = []
        for raw in splitLines(text) {
            let line = strip(stripChar(strip(raw), "*"))
            if line.hasPrefix("## ") {
                if let t = title, !names.isEmpty {
                    stories.append(AnnotatedStory(title: t, fileNames: dedup(names)))
                }
                title = strip(String(line.dropFirst(3)))
                names = []
            } else if !line.isEmpty, title != nil {
                let candidate = strip(stripChar(line, "`"))
                if !videoExtensions.contains(suffix(candidate)) { names.append(candidate) }
            }
        }
        if let t = title, !names.isEmpty {
            stories.append(AnnotatedStory(title: t, fileNames: dedup(names)))
        }
        return stories
    }

    public static func evaluateDatabase(database: String, annotations: String, runId: String?) throws -> JSONValue {
        let expected = try parseAnnotations(path: annotations)
        let db = try Database.open(path: database)
        var runId = runId
        if runId == nil {
            let rows = try db.query("SELECT id FROM analysis_runs ORDER BY completed_at DESC LIMIT 1", [])
            guard let row = rows.first else { throw AilbumError.invalid("В базе нет запусков анализа") }
            runId = JSONValue(row["id"] ?? .null).stringValue ?? String(describing: row["id"]!)
        }
        let rows = try db.query(
            """
            SELECT i.file_name, pa.story_id, s.title
            FROM photo_analysis AS pa
            JOIN images AS i ON i.id = pa.image_id
            LEFT JOIN stories AS s
              ON s.run_id = pa.run_id AND s.story_id = pa.story_id
            WHERE pa.run_id = ?
            """, [.text(runId!)])
        var predictions: [String: (Int, String)] = [:]
        for row in rows {
            guard case .integer(let sid)? = row["story_id"], case .text(let name)? = row["file_name"] else { continue }
            var title = ""
            if case .text(let t)? = row["title"] { title = t }
            predictions[name] = (Int(sid), title)
        }
        return evaluateGroups(expected: expected, predictions: predictions, runId: runId)
    }

    /// Insertion-ordered counter (Python `Counter`).
    private struct Counter<K: Hashable> {
        var keys: [K] = []
        var counts: [K: Int] = [:]
        mutating func add(_ k: K) {
            if counts[k] == nil { keys.append(k) }
            counts[k, default: 0] += 1
        }
        subscript(k: K) -> Int { counts[k] ?? 0 }
        var values: [Int] { keys.map { counts[$0]! } }
        var mostCommon: K? {
            var best: K?
            for k in keys where best == nil || counts[k]! > counts[best!]! { best = k }
            return best
        }
    }

    private struct Pair: Hashable { var a: Int; var b: Int }

    static func round4(_ x: Double) -> Double { Double(String(format: "%.4f", x)) ?? x }
    private static func pairs(_ n: Int) -> Int { n * (n - 1) / 2 }
    private static func ratio(_ n: Int, _ d: Int) -> Double { d != 0 ? Double(n) / Double(d) : 0.0 }
    private static func f1(_ p: Double, _ r: Double) -> Double { p + r != 0 ? 2 * p * r / (p + r) : 0.0 }
    private static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0.0 : v.reduce(0, +) / Double(v.count) }

    public static func evaluateGroups(
        expected: [AnnotatedStory], predictions: [String: (Int, String)], runId: String?
    ) -> JSONValue {
        var truthByFile: [String: Int] = [:]
        var truthOrder: [String] = []
        for (tid, story) in expected.enumerated() {
            for f in story.fileNames {
                if truthByFile[f] == nil { truthOrder.append(f) }
                truthByFile[f] = tid
            }
        }
        let found = truthOrder.filter { predictions[$0] != nil }
        var truthSizes = Counter<Int>()
        var predictedSizes = Counter<Int>()
        var contingency = Counter<Pair>()
        for f in found {
            truthSizes.add(truthByFile[f]!)
            predictedSizes.add(predictions[f]!.0)
            contingency.add(Pair(a: truthByFile[f]!, b: predictions[f]!.0))
        }
        let truePairs = truthSizes.values.reduce(0) { $0 + pairs($1) }
        let predictedPairs = predictedSizes.values.reduce(0) { $0 + pairs($1) }
        let matchingPairs = contingency.values.reduce(0) { $0 + pairs($1) }
        let pairPrecision = ratio(matchingPairs, predictedPairs)
        let pairRecall = ratio(matchingPairs, truePairs)

        var bPrecision: [Double] = []
        var bRecall: [Double] = []
        for f in found {
            let tid = truthByFile[f]!
            let pid = predictions[f]!.0
            let inter = contingency[Pair(a: tid, b: pid)]
            bPrecision.append(Double(inter) / Double(predictedSizes[pid]))
            bRecall.append(Double(inter) / Double(truthSizes[tid]))
        }

        var perStory: [JSONValue] = []
        var titleScores: [Double] = []
        var completenessValues: [Double] = []
        for story in expected {
            let storyFound = story.fileNames.filter { predictions[$0] != nil }
            var assignments = Counter<Int>()
            for n in storyFound { assignments.add(predictions[n]!.0) }
            let dominant = assignments.mostCommon
            let completeness = dominant.map { Double(assignments[$0]) / Double(storyFound.count) } ?? 0.0
            var predictedTitle = ""
            if let d = dominant, let n = storyFound.first(where: { predictions[$0]!.0 == d }) {
                predictedTitle = predictions[n]!.1
            }
            let sim = titleSimilarity(story.title, predictedTitle)
            if !predictedTitle.isEmpty { titleScores.append(sim) }
            var ids: [String: JSONValue] = [:]
            for k in assignments.keys { ids[String(k)] = .int(assignments[k]) }
            let c4 = round4(completeness)
            completenessValues.append(c4)
            perStory.append(.object([
                "expected_title": .string(story.title),
                "photos": .int(story.fileNames.count),
                "found": .int(storyFound.count),
                "predicted_story_ids": .object(ids),
                "dominant_story_id": dominant.map { .int($0) } ?? .null,
                "completeness": .double(c4),
                "predicted_title": .string(predictedTitle),
                "title_similarity": .double(round4(sim)),
            ]))
        }

        let homogeneity: [Double] = predictedSizes.keys.map { pid in
            let best = truthSizes.keys.map { contingency[Pair(a: $0, b: pid)] }.max() ?? 0
            return Double(best) / Double(predictedSizes[pid])
        }
        let bp = mean(bPrecision)
        let br = mean(bRecall)
        return .object([
            "run_id": runId.map { .string($0) } ?? .null,
            "annotated_stories": .int(expected.count),
            "annotated_photos": .int(truthByFile.count),
            "matched_photos": .int(found.count),
            "coverage": .double(round4(ratio(found.count, truthByFile.count))),
            "pairwise_precision": .double(round4(pairPrecision)),
            "pairwise_recall": .double(round4(pairRecall)),
            "pairwise_f1": .double(round4(f1(pairPrecision, pairRecall))),
            "bcubed_precision": .double(round4(bp)),
            "bcubed_recall": .double(round4(br)),
            "bcubed_f1": .double(round4(f1(bp, br))),
            "macro_completeness": .double(round4(mean(completenessValues))),
            "minimum_completeness": .double(round4(completenessValues.min() ?? 0.0)),
            "macro_homogeneity": .double(round4(mean(homogeneity))),
            "complete_stories": .int(completenessValues.filter { $0 == 1.0 }.count),
            "mixed_predicted_stories": .int(homogeneity.filter { $0 < 1.0 }.count),
            "mean_title_similarity": .double(round4(mean(titleScores))),
            "stories": .array(perStory),
        ])
    }

    private static func normalizeTitle(_ value: String) -> [UInt32] {
        var out: [UInt32] = []
        var inWord = false
        for s in value.lowercased().unicodeScalars {
            let v = s.value
            let ok = (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
                || (v >= 0x430 && v <= 0x44F) || v == 0x451
            if ok {
                if !inWord, !out.isEmpty { out.append(0x20) }
                out.append(v)
                inWord = true
            } else {
                inWord = false
            }
        }
        return out
    }

    static func titleSimilarity(_ expected: String, _ predicted: String) -> Double {
        let l = normalizeTitle(expected)
        let r = normalizeTitle(predicted)
        return l.isEmpty || r.isEmpty ? 0.0 : sequenceRatio(l, r)
    }

    /// difflib.SequenceMatcher(None, a, b).ratio() with autojunk=True.
    static func sequenceRatio(_ a: [UInt32], _ b: [UInt32]) -> Double {
        var b2j: [UInt32: [Int]] = [:]
        for (i, e) in b.enumerated() { b2j[e, default: []].append(i) }
        if b.count >= 200 {
            let ntest = b.count / 100 + 1
            for (k, v) in b2j where v.count > ntest { b2j[k] = nil }
        }

        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var newj2len: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                j2len = newj2len
            }
            while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
                besti -= 1; bestj -= 1; bestsize += 1
            }
            while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
                bestsize += 1
            }
            return (besti, bestj, bestsize)
        }

        var matches = 0
        var queue = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            if k > 0 {
                matches += k
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        return 2.0 * Double(matches) / Double(a.count + b.count)
    }
}
