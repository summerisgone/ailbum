import Foundation

/// Port of desktop_job.py: `ailbum-swift job <kind> ...` emitting JSON-lines events.
public enum DesktopJob {
    typealias GenerateSeam = (String, Int, LayoutParams, String?, LayoutService.Progress?) throws -> JSONValue
    typealias AnalyzeSeam = (String, String, PipelineConfig, ((String) -> Void)?, String) throws -> JSONValue
    typealias IndexSeam = (String, String, ((Int, Int) -> Void)?) throws -> JSONValue

    nonisolated(unsafe) static var generateOverride: GenerateSeam?
    nonisolated(unsafe) static var analyzeOverride: AnalyzeSeam?
    nonisolated(unsafe) static var indexOverride: IndexSeam?

    struct JobFailure: Error {
        let type: String
        let message: String
    }

    // MARK: progress

    private static func capture(_ pattern: String, _ message: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = message as NSString
        guard let m = re.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    public static func progressEvent(_ message: String, defaultStage: String = "Анализ фотографий") -> JSONValue {
        if let g = capture(#"^Этап:\s*([^|]+)(?:\|(.*))?$"#, message), let stage = g[0] {
            return [
                "type": "progress",
                "stage": .string(stage.trimmingCharacters(in: .whitespacesAndNewlines)),
                "detail": .string((g[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
            ]
        }
        if let g = capture(#"^\[(\d+)/(\d+)\]\s*(.*)$"#, message),
           let current = g[0].flatMap({ Int($0) }), let total = g[1].flatMap({ Int($0) }) {
            return [
                "type": "progress", "stage": .string(defaultStage), "current": .int(current),
                "total": .int(total), "detail": .string(g[2] ?? ""),
            ]
        }
        return ["type": "progress", "stage": "Обработка", "detail": .string(message)]
    }

    // MARK: params and config

    private static func pyInt(_ v: JSONValue?, _ key: String) throws -> Int {
        switch v {
        case .int(let i)?: return i
        case .double(let d)?:
            guard d.isFinite else { throw JobFailure(type: "ValueError", message: "cannot convert float \(d) to integer") }
            return Int(d)
        case .bool(let b)?: return b ? 1 : 0
        case .string(let s)?:
            guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else {
                throw JobFailure(type: "ValueError", message: "invalid literal for int() with base 10: '\(s)'")
            }
            return i
        case nil: throw JobFailure(type: "KeyError", message: "'\(key)'")
        default:
            throw JobFailure(type: "TypeError", message: "int() argument must be a string or a real number")
        }
    }

    private static func pyFalsy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .bool(let b): return !b
        case .int(let i): return i == 0
        case .double(let d): return d == 0
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        }
    }

    private static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? ""
        }
    }

    public static func layoutParams(_ raw: String) throws -> LayoutParams {
        let values: JSONValue
        do { values = try JSONValue.parse(raw) } catch {
            throw JobFailure(type: "JSONDecodeError", message: "Expecting value")
        }
        guard case .object(let o) = values else {
            throw JobFailure(type: "TypeError", message: "Параметры раскладки должны быть JSON-объектом")
        }
        guard let orientation = o["orientation"] else { throw JobFailure(type: "KeyError", message: "'orientation'") }
        let spread = try pyInt(o["spread_count"], "spread_count")
        let minPhotos = try pyInt(o["min_photos"], "min_photos")
        let maxPhotos = try pyInt(o["max_photos"], "max_photos")
        let assistant = o["assistant"].map(pyStr) ?? "auto"
        var prompt = ""
        if let p = o["prompt"], !pyFalsy(p) { prompt = pyStr(p) }
        return LayoutParams(
            orientation: pyStr(orientation), spreadCount: spread, minPhotos: minPhotos, maxPhotos: maxPhotos,
            assistant: assistant, prompt: String(String.UnicodeScalarView(prompt.unicodeScalars.prefix(Preferences.maxPrompt))))
    }

    static func pipelineConfig(_ raw: [String: JSONValue]?) -> PipelineConfig {
        var c = PipelineConfig()
        for (key, v) in raw ?? [:] {
            switch key {
            case "sharpness_threshold": if let d = v.doubleValue { c.sharpnessThreshold = d }
            case "photo_hash_distance": if let i = v.intValue { c.photoHashDistance = i }
            case "photo_hist_similarity": if let d = v.doubleValue { c.photoHistSimilarity = d }
            case "photo_geometric_similarity": c.photoGeometricSimilarity = v.doubleValue
            case "geometric_max_features": if let i = v.intValue { c.geometricMaxFeatures = i }
            case "geometric_neighbor_window": if let i = v.intValue { c.geometricNeighborWindow = i }
            case "geometric_time_window_minutes": if let i = v.intValue { c.geometricTimeWindowMinutes = i }
            case "face_similarity": c.faceSimilarity = v.doubleValue
            case "min_face_size": if let i = v.intValue { c.minFaceSize = i }
            case "min_attribute_face_size": if let i = v.intValue { c.minAttributeFaceSize = i }
            case "max_image_side": if let i = v.intValue { c.maxImageSide = i }
            case "face_backend": if let s = v.stringValue { c.faceBackend = s }
            case "semantic_backend": if let s = v.stringValue { c.semanticBackend = s }
            case "clip_model": if let s = v.stringValue { c.clipModel = s }
            case "semantic_threshold": if let d = v.doubleValue { c.semanticThreshold = d }
            case "semantic_top_k": if let i = v.intValue { c.semanticTopK = i }
            case "semantic_batch_size": if let i = v.intValue { c.semanticBatchSize = i }
            case "semantic_device": if let s = v.stringValue { c.semanticDevice = s }
            case "story_gap_minutes": if let i = v.intValue { c.storyGapMinutes = i }
            case "story_continuity_minutes": if let i = v.intValue { c.storyContinuityMinutes = i }
            case "story_max_duration_hours": if let i = v.intValue { c.storyMaxDurationHours = i }
            case "story_semantic_break_minutes": if let i = v.intValue { c.storySemanticBreakMinutes = i }
            case "story_naming_backend": if let s = v.stringValue { c.storyNamingBackend = s }
            case "lmstudio_url": if let s = v.stringValue { c.lmstudioUrl = s }
            case "lmstudio_model": if let s = v.stringValue { c.lmstudioModel = s }
            case "story_vlm_images": if let i = v.intValue { c.storyVlmImages = i }
            case "story_vlm_timeout": if let d = v.doubleValue { c.storyVlmTimeout = d }
            case "models_dir": if let s = v.stringValue { c.modelsDir = URL(fileURLWithPath: s) }
            case "feature_cache": if let b = v.boolValue { c.featureCache = b }
            case "feature_cache_dir": c.featureCacheDir = v.stringValue.map { URL(fileURLWithPath: $0) }
            default: break
            }
        }
        return c
    }

    private static func resolved(_ path: String) -> String {
        Catalog.resolve(path)
    }

    private static func latestAnalysis(_ database: String) throws -> (source: String, output: String, config: [String: JSONValue])? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        let db = try Database.open(path: database)
        let rows = try db.query(
            """
            SELECT source, output, config_json FROM analysis_runs
            WHERE status = 'completed' ORDER BY completed_at DESC LIMIT 1
            """, [])
        guard let row = rows.first, case .text(let source)? = row["source"], case .text(let output)? = row["output"]
        else { return nil }
        var config: [String: JSONValue] = [:]
        if case .text(let json)? = row["config_json"], case .object(let o)? = try? JSONValue.parse(json) { config = o }
        return (source, output, config)
    }

    // MARK: jobs

    static func runIndex(_ database: String, _ sources: [String], emit: (JSONValue) -> Void) throws -> JSONValue {
        var summaries: [JSONValue] = []
        for (offset, source) in sources.enumerated() {
            emit([
                "type": "progress", "stage": "Добавление фотографий",
                "detail": .string("Папка \(offset + 1) из \(sources.count): \((source as NSString).lastPathComponent)"),
            ])
            let report: (Int, Int) -> Void = { i, n in
                emit(progressEvent("[\(i)/\(n)]", defaultStage: "Добавление фотографий"))
            }
            let summary = try withoutActuallyEscaping(report) { escaping in
                try (indexOverride ?? { s, d, p in try Catalog.indexLibrary(source: s, database: d, recursive: true, progress: p) })(
                    source, database, escaping)
            }
            var entry: [String: JSONValue] = summary.objectValue ?? [:]
            entry["source"] = .string(resolved(source))
            summaries.append(.object(entry))
        }
        return ["sources": .array(summaries)]
    }

    static func runAnalysis(
        _ database: String, source: String?, output: String?, modelsDir: String?, emit: (JSONValue) -> Void
    ) throws -> JSONValue {
        let previous = try latestAnalysis(database)
        guard let actualSource = source ?? previous?.source else {
            throw AilbumError.invalid("Сначала перетащите папку с фотографиями")
        }
        let actualOutput: String
        if let output { actualOutput = output }
        else if let previous, source == nil { actualOutput = previous.output }
        else { actualOutput = ((database as NSString).deletingLastPathComponent as NSString).appendingPathComponent("analysis-output") }
        var config = pipelineConfig(previous?.config)
        if let modelsDir { config.modelsDir = URL(fileURLWithPath: modelsDir) }
        let report: (String) -> Void = { emit(progressEvent($0)) }
        let manifest = try withoutActuallyEscaping(report) { escaping in
            try (analyzeOverride ?? { s, o, c, p, d in
                try Pipeline.analyzeLibrary(source: s, output: o, config: c, recursive: true, progress: p, database: d)
            })(actualSource, actualOutput, config, escaping, database)
        }
        guard let runId = manifest["run_id"]?.stringValue else { throw JobFailure(type: "KeyError", message: "'run_id'") }
        let db = try Database.open(path: database)
        let albumId = try Albums.attachRun(db, runId: runId, sources: [resolved(actualSource)])
        return ["run_id": .string(runId), "album_id": .int(albumId), "summary": manifest["summary"] ?? .null]
    }

    static func runLayout(
        _ database: String, albumId: Int, rawParams: String, modelsDir: String?, emit: (JSONValue) -> Void
    ) throws -> JSONValue {
        let params = try layoutParams(rawParams)
        let report: LayoutService.Progress = { stage, detail, current, total in
            emit([
                "type": "progress", "stage": .string(stage), "detail": .string(detail),
                "current": current.map { .int($0) } ?? .null, "total": total.map { .int($0) } ?? .null,
            ])
        }
        return try withoutActuallyEscaping(report) { escaping in
            try (generateOverride ?? { d, a, p, m, r in
                try LayoutService.generate(database: d, albumId: a, params: p, modelsDir: m, progress: r)
            })(database, albumId, params, modelsDir, escaping)
        }
    }

    // MARK: entry

    static func errorText(_ error: Error) -> String {
        if let f = error as? JobFailure { return "\(f.type): \(f.message)" }
        if let e = error as? AilbumError {
            switch e {
            case .invalid(let m): return "ValueError: \(m)"
            case .sqlite(let m): return "OperationalError: \(m)"
            case .schemaTooOld(let v): return "RuntimeError: schema version \(v) is too old"
            case .decode(let m): return "ValueError: \(m)"
            case .metal(let m): return "RuntimeError: \(m)"
            }
        }
        return "\(type(of: error)): \(error.localizedDescription)"
    }

    private struct Parsed {
        var kind = ""
        var database: String?
        var sources: [String] = []
        var output: String?
        var modelsDir: String?
        var albumId: Int?
        var params: String?
    }

    private static func parse(_ args: [String]) throws -> Parsed {
        var p = Parsed()
        let valued: Set<String> = ["--database", "--source", "--output", "--models-dir", "--album-id", "--params"]
        var i = 0
        func fail(_ m: String) -> JobFailure { JobFailure(type: "ArgumentError", message: m) }
        while i < args.count {
            var token = args[i]
            var inline: String?
            if token.hasPrefix("--"), let eq = token.firstIndex(of: "=") {
                inline = String(token[token.index(after: eq)...])
                token = String(token[..<eq])
            }
            i += 1
            if valued.contains(token) {
                var value = inline
                if value == nil {
                    guard i < args.count else { throw fail("argument \(token): expected one argument") }
                    value = args[i]
                    i += 1
                }
                let v = value!
                switch token {
                case "--database": p.database = v
                case "--source": p.sources.append(v)
                case "--output": p.output = v
                case "--models-dir": p.modelsDir = v
                case "--album-id":
                    guard let n = Int(v) else { throw fail("argument --album-id: invalid int value: '\(v)'") }
                    p.albumId = n
                default: p.params = v
                }
            } else if token.hasPrefix("--") {
                throw fail("unrecognized arguments: \(token)")
            } else if p.kind.isEmpty {
                guard ["index", "analyze", "layout"].contains(token) else {
                    throw fail("argument kind: invalid choice: '\(token)' (choose from 'index', 'analyze', 'layout')")
                }
                p.kind = token
            } else {
                throw fail("unrecognized arguments: \(token)")
            }
        }
        if p.kind.isEmpty { throw fail("the following arguments are required: kind") }
        if p.database == nil { throw fail("the following arguments are required: --database") }
        return p
    }

    public static func run(_ args: [String], emit: (JSONValue) -> Void) -> Int32 {
        do {
            let a = try parse(args)
            let database = a.database!
            let result: JSONValue
            switch a.kind {
            case "layout":
                guard let albumId = a.albumId, let params = a.params else {
                    throw AilbumError.invalid("Не указаны альбом и параметры раскладки")
                }
                result = try runLayout(database, albumId: albumId, rawParams: params, modelsDir: a.modelsDir, emit: emit)
            case "index":
                if a.sources.isEmpty { throw AilbumError.invalid("Не выбраны папки с фотографиями") }
                result = try runIndex(database, a.sources, emit: emit)
            default:
                if a.sources.count > 1 { throw AilbumError.invalid("Одновременно можно анализировать только одну папку") }
                result = try runAnalysis(database, source: a.sources.first, output: a.output, modelsDir: a.modelsDir, emit: emit)
            }
            emit(["type": "complete", "result": result])
            return 0
        } catch {
            emit(["type": "error", "error": .string(errorText(error))])
            return 2
        }
    }
}
