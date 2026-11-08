import Foundation

/// What the service needs from the VLM assistant (a seam so tests inject fakes).
protocol LayoutAssisting {
    func connect() throws -> Bool
    func choose(
        _ variants: [SpreadDraft], paths: [Int: String], orientation: String, storyTitle: String, wish: String
    ) throws -> AssistantChoice?
}

extension LayoutAssistant: LayoutAssisting {}

public enum LayoutService {
    public typealias Progress = (String, String, Int?, Int?) -> Void
    typealias Detector = (RGBImage) throws -> [DetectedObject]

    public static let detectorWarning =
        "Модель детектора объектов не найдена: защита областей только по лицам и saliency"
    public static let assistantWarning = "AI-редактор недоступен: использован выбор движка"

    /// Test seams: replace the detector lookup and the assistant constructor (baseURL, model).
    nonisolated(unsafe) static var detectorFactory: ((String?) -> Detector?)?
    nonisolated(unsafe) static var assistantFactory: ((String, String) -> LayoutAssisting)?

    struct Entry {
        var storyId: Int?
        var title: String
        var group: StoryGroup
    }

    public static func preflight(database: String, albumId: Int, params: LayoutParams) throws -> JSONValue {
        let db = try Database.open(path: database)
        let pool = try Facts.loadPool(db, albumId: albumId, detector: nil, progress: nil)
        let (groups, _) = try groupPool(db, runId: LayoutStore.albumRun(db, albumId: albumId), pool: pool)
        return try summary(params, poolCount: pool.count, groups: groups)
    }

    public static func generate(
        database: String, albumId: Int, params: LayoutParams, modelsDir: String?,
        progress: Progress? = nil
    ) throws -> JSONValue {
        let report: Progress = progress ?? { _, _, _, _ in }
        var warnings: [String] = []
        let db = try Database.open(path: database)
        try LayoutStore.requireDraft(db, albumId: albumId)
        let runId = try LayoutStore.albumRun(db, albumId: albumId)
        let detector = openDetector(modelsDir)
        if detector == nil { warnings.append(detectorWarning) }
        report("Анализ объектов", "Анализ объектов", 0, nil)
        var pool = try Facts.loadPool(db, albumId: albumId, detector: detector) { done, total in
            report("Анализ объектов", "Анализ объектов", done, total)
        }
        pool = Preferences.apply(pool, Preferences.parse(params.prompt))
        let (groups, members) = try groupPool(db, runId: runId, pool: pool)
        let info = try summary(params, poolCount: pool.count, groups: groups)
        let errors = (info["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
        if !errors.isEmpty { throw AilbumError.invalid(errors.joined(separator: "\n")) }
        warnings.append(contentsOf: (info["warnings"]?.arrayValue ?? []).compactMap(\.stringValue))

        let allocations = try SpreadAllocation.allocateSpreads(
            groups.map(\.group), spreadCount: params.spreadCount, minPhotos: params.minPhotos,
            maxPhotos: params.maxPhotos)
        let (assistant, assistantModel) = try openAssistant(db, runId: runId, params: params)
        if params.assistant != "off" && assistant == nil { warnings.append(assistantWarning) }

        let paths = try imagePaths(database: database, db, pool.map(\.imageId))
        var titles: [Int: String] = [:]
        for entry in groups { if let id = entry.storyId { titles[id] = entry.title } }
        var spreads: [SpreadDraft] = []
        var unplaced: [JSONValue] = []
        let total = allocations.count
        var cursor = 0
        for (index, allocation) in allocations.enumerated() {
            report("Компоновка", "Компоновка", index, total)
            let taken: [Int?]
            (taken, cursor) = takeGroups(groups, cursor: cursor, allocation: allocation, last: index == total - 1)
            let photos = taken.flatMap { members[$0] ?? [] }
            let composed = try Composer.composeGroup(photos, allocation: allocation, params: params)
            unplaced.append(contentsOf: composed.unplaced)
            let title = taken.compactMap { key in key.flatMap { titles[$0] }.flatMap { $0.isEmpty ? nil : $0 } }
                .joined(separator: " + ")
            for spread in composed.spreads {
                spreads.append(refine(spread, params, assistant, paths, title, report))
            }
        }
        report("Компоновка", "Компоновка", total, total)

        try LayoutStore.saveLayout(
            db, albumId: albumId, runId: runId, params: params, spreads: spreads, unplaced: unplaced,
            warnings: warnings, selectionHash: LayoutStore.selectionHash(db, albumId: albumId),
            assistantModel: assistant != nil ? assistantModel : nil)
        return try LayoutStore.loadLayout(db, albumId: albumId) ?? .object([:])
    }

    // MARK: refine

    static func refine(
        _ spread: SpreadDraft, _ params: LayoutParams, _ assistant: LayoutAssisting?,
        _ paths: [Int: String], _ title: String, _ report: Progress
    ) -> SpreadDraft {
        guard let assistant else { return spread }
        report("AI-редактор", "AI-редактор", nil, nil)
        let variants = [spread] + spread.alternatives
        if variants.count < 2 { return spread }
        let choice: AssistantChoice?
        do {
            choice = try assistant.choose(
                variants, paths: paths, orientation: params.orientation, storyTitle: title, wish: params.prompt)
        } catch {
            return spread
        }
        guard let choice, variants.indices.contains(choice.index) else { return spread }
        var picked = variants[choice.index]
        picked.assistantReason = choice.reason
        return picked
    }

    // MARK: summary

    static func validate(_ params: LayoutParams, unitCount: Int) -> [String] {
        var errors: [String] = []
        if params.spreadCount < 1 { errors.append("Число разворотов должно быть не меньше 1") }
        for value in [params.minPhotos, params.maxPhotos] where !(1...8).contains(value) {
            errors.append("Число фото на коллаже должно быть от 1 до 8")
            break
        }
        if params.minPhotos > params.maxPhotos {
            errors.append("Минимум фото на коллаже не может быть больше максимума")
        }
        if params.spreadCount >= 1 && unitCount < params.spreadCount {
            errors.append("Кадров меньше, чем разворотов")
        }
        return errors
    }

    private static func joinedTitles(_ ids: [Int], _ titles: [Int: String]) -> String {
        ids.compactMap { id in titles[id].flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " + ")
    }

    static func summary(_ params: LayoutParams, poolCount: Int, groups: [Entry]) throws -> JSONValue {
        let unitCount = groups.reduce(0) { $0 + $1.group.unitCount }
        let errors = validate(params, unitCount: unitCount)
        var warnings: [String] = []
        let minNeeded = max(params.spreadCount, 0) * params.minPhotos
        let maxUsed = max(params.spreadCount, 0) * params.maxPhotos
        var allocation: [JSONValue] = []
        if errors.isEmpty {
            var titles: [Int: String] = [:]
            for entry in groups { if let id = entry.storyId { titles[id] = entry.title } }
            for item in try SpreadAllocation.allocateSpreads(
                groups.map(\.group), spreadCount: params.spreadCount, minPhotos: params.minPhotos,
                maxPhotos: params.maxPhotos) {
                allocation.append([
                    "story_ids": .array(item.storyIds.map { .int($0) }),
                    "title": .string(joinedTitles(item.storyIds, titles)),
                    "spreads": .int(item.spreads),
                    "units": .int(item.unitCount),
                ])
                if item.merged { warnings.append("Сюжеты объединены на одном развороте") }
            }
            if unitCount < minNeeded { warnings.append("Кадров меньше минимума: часть коллажей будет неполной") }
            if unitCount > maxUsed { warnings.append("Часть кадров не поместится в раскладку") }
        }
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0).inserted }
        return [
            "pool_count": .int(poolCount),
            "unit_count": .int(unitCount),
            "story_count": .int(groups.filter { $0.storyId != nil }.count),
            "min_needed": .int(minNeeded),
            "max_used": .int(maxUsed),
            "allocation": .array(allocation),
            "errors": .array(errors.map { .string($0) }),
            "warnings": .array(unique.map { .string($0) }),
        ]
    }

    // MARK: grouping

    /// Units go to one story each; the story of the lowest selected image decides.
    static func groupPool(
        _ db: Database, runId: String, pool: [PhotoFacts]
    ) throws -> ([Entry], [Int?: [PhotoFacts]]) {
        var unitOrder: [String] = []
        var units: [String: [PhotoFacts]] = [:]
        for photo in pool {
            if units[photo.unitKey] == nil { unitOrder.append(photo.unitKey) }
            units[photo.unitKey, default: []].append(photo)
        }
        var members: [Int?: [PhotoFacts]] = [:]
        var unitCounts: [Int?: Int] = [:]
        for key in unitOrder {
            let unit = units[key] ?? []
            guard let lead = unit.min(by: { a, b in
                (a.selected ? 0 : 1, a.imageId) < (b.selected ? 0 : 1, b.imageId)
            }) else { continue }
            members[lead.storyId, default: []].append(contentsOf: unit)
            unitCounts[lead.storyId, default: 0] += 1
        }
        var rows: [Int: [String: SQLValue]] = [:]
        for row in try db.query(
            "SELECT story_id, title, started_at, ended_at FROM stories WHERE run_id = ?", [.text(runId)]) {
            if case .integer(let id)? = row["story_id"] { rows[Int(id)] = row }
        }
        func started(_ k: Int?) -> String? {
            if let k, case .text(let s)? = rows[k]?["started_at"] { return s }
            return nil
        }
        func order(_ k: Int?) -> (Int, Int, String, Int) {
            let known = k.map { rows[$0] != nil } ?? false
            let s = started(k)
            return (k == nil ? 1 : 0, known ? (s == nil ? 1 : 0) : 1, s ?? "", k ?? 0)
        }
        let keys = members.keys.sorted { order($0) < order($1) }
        var groups: [Entry] = []
        for key in keys {
            let row = key.flatMap { rows[$0] }
            var title = ""
            if case .text(let t)? = row?["title"] { title = t }
            var ended: String?
            if case .text(let e)? = row?["ended_at"] { ended = e }
            groups.append(Entry(
                storyId: key, title: title,
                group: StoryGroup(
                    storyIds: key.map { [$0] } ?? [], unitCount: unitCounts[key] ?? 0,
                    startedAt: started(key), endedAt: ended)))
        }
        return (groups, members)
    }

    static func takeGroups(
        _ groups: [Entry], cursor start: Int, allocation: Allocation, last: Bool
    ) -> ([Int?], Int) {
        var remaining = Set(allocation.storyIds)
        var taken: [Int?] = []
        var cursor = start
        while cursor < groups.count {
            let key = groups[cursor].storyId
            if let key {
                if remaining.contains(key) { remaining.remove(key) } else { break }
            } else if !remaining.isEmpty || !(last || allocation.storyIds.isEmpty) {
                break
            }
            taken.append(key)
            cursor += 1
        }
        return (taken, cursor)
    }

    // MARK: collaborators

    static func openDetector(_ modelsDir: String?) -> Detector? {
        if let detectorFactory { return detectorFactory(modelsDir) }
        guard let modelsDir else { return nil }
        // The model itself is resolved by ModelStore; the directory only gates availability.
        guard FileManager.default.fileExists(atPath: modelsDir + "/yolox.mlpackage") else { return nil }
        return { try YOLOX.detect($0) }
    }

    static func openAssistant(
        _ db: Database, runId: String, params: LayoutParams
    ) throws -> (LayoutAssisting?, String?) {
        if params.assistant == "off" { return (nil, nil) }
        var config: [String: JSONValue] = [:]
        let row = try db.query("SELECT config_json FROM analysis_runs WHERE id = ?", [.text(runId)]).first
        if case .text(let text)? = row?["config_json"], let object = try JSONValue.parse(text).objectValue {
            config = object
        }
        let model = config["lmstudio_model"]?.stringValue ?? "qwen/qwen3-vl-2b"
        let url = config["lmstudio_url"]?.stringValue ?? "http://127.0.0.1:1234/v1"
        let assistant: LayoutAssisting = assistantFactory?(url, model) ?? LayoutAssistant(baseURL: url, model: model)
        let connected = (try? assistant.connect()) ?? false
        return connected ? (assistant, model) : (nil, nil)
    }

    static func imagePaths(database: String, _ db: Database, _ imageIds: [Int]) throws -> [Int: String] {
        var paths: [Int: String] = [:]
        var start = 0
        while start < imageIds.count {
            let chunk = Array(imageIds[start..<min(start + 500, imageIds.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            for row in try db.query(
                "SELECT id, path, sha256, availability FROM images WHERE id IN (\(marks))",
                chunk.map { .integer($0) }) {
                if case .integer(let id)? = row["id"],
                   let source = Proxies.imageSource(database: database, image: row) {
                    paths[Int(id)] = source
                }
            }
            start += 500
        }
        return paths
    }
}
