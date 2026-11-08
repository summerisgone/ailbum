import Foundation

/// Port of the analyze/index/db/people/models/compare/evaluate handlers of src/ailbum/cli.py.
public enum CLICatalog {
    typealias AnalyzeFn = (String, String, PipelineConfig, Bool, ((String) -> Void)?, String?) throws -> JSONValue
    /// Test seam: replaces `Pipeline.analyzeLibrary`.
    nonisolated(unsafe) static var analyzeOverride: AnalyzeFn?

    static let defaultDatabase = ".ailbum/ailbum.sqlite3"
    static let modelNames = ["yunet", "sface", "eye", "expression", "yolox", "clip_vision"]

    // MARK: argument parsing (argparse subset)

    struct Parsed {
        var positionals: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]

        func string(_ key: String, _ fallback: String) -> String { values[key] ?? fallback }
        func int(_ key: String, _ fallback: Int) throws -> Int {
            guard let raw = values[key] else { return fallback }
            guard let v = Int(raw) else { throw AilbumError.invalid("argument --\(key): invalid int value: '\(raw)'") }
            return v
        }
        func double(_ key: String, _ fallback: Double) throws -> Double {
            guard let raw = values[key] else { return fallback }
            guard let v = Double(raw) else { throw AilbumError.invalid("argument --\(key): invalid float value: '\(raw)'") }
            return v
        }
        func choice(_ key: String, _ fallback: String, _ allowed: [String]) throws -> String {
            guard let raw = values[key] else { return fallback }
            guard allowed.contains(raw) else {
                throw AilbumError.invalid("argument --\(key): invalid choice: '\(raw)' (choose from \(allowed.joined(separator: ", ")))")
            }
            return raw
        }
    }

    /// `valueOptions` and `flagOptions` map spellings (`-o`, `--output`) to a canonical key.
    static func parse(_ args: [String], valueOptions: [String: String], flagOptions: [String: String]) throws -> Parsed {
        var result = Parsed()
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                guard let key = valueOptions[name] else { throw AilbumError.invalid("unrecognized arguments: \(arg)") }
                result.values[key] = String(arg[arg.index(after: eq)...])
            } else if let key = valueOptions[arg] {
                guard index < args.count else { throw AilbumError.invalid("argument \(arg): expected one argument") }
                result.values[key] = args[index]
                index += 1
            } else if let key = flagOptions[arg] {
                result.flags.insert(key)
            } else if arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil {
                throw AilbumError.invalid("unrecognized arguments: \(arg)")
            } else {
                result.positionals.append(arg)
            }
        }
        return result
    }

    static func positionalInt(_ raw: String, _ name: String) throws -> Int {
        guard let v = Int(raw) else { throw AilbumError.invalid("argument \(name): invalid int value: '\(raw)'") }
        return v
    }

    static func exactly(_ parsed: Parsed, _ names: [String]) throws {
        if parsed.positionals.count < names.count {
            throw AilbumError.invalid("the following arguments are required: \(names[parsed.positionals.count...].joined(separator: ", "))")
        }
        if parsed.positionals.count > names.count {
            throw AilbumError.invalid("unrecognized arguments: \(parsed.positionals[names.count...].joined(separator: " "))")
        }
    }

    static func dump(_ value: JSONValue) -> String { Pipeline.dump(value, 0) }

    // MARK: entry

    /// Returns nil when `args` is not a command of this file.
    public static func run(_ args: [String], out: (String) -> Void) throws -> Int32? {
        guard let command = args.first else { return nil }
        let rest = Array(args.dropFirst())
        let dbOption = ["--database": "database"]
        switch command {
        case "analyze": return try analyze(rest, out: out)
        case "index": return try index(rest, out: out)
        case "db":
            guard let sub = rest.first, ["stats", "list", "show"].contains(sub) else { return nil }
            return try database(sub, Array(rest.dropFirst()), out: out)
        case "people":
            guard let sub = rest.first, ["list", "show", "name", "merge", "compose"].contains(sub) else { return nil }
            return try people(sub, Array(rest.dropFirst()), out: out)
        case "models", "download-models":
            let p = try parse(rest, valueOptions: ["--models-dir": "models-dir"], flagOptions: [:])
            try exactly(p, [])
            let previous = getenv("AILBUM_MODELS_DIR").map { String(cString: $0) }
            if let dir = p.values["models-dir"] { setenv("AILBUM_MODELS_DIR", dir, 1) }
            defer {
                if p.values["models-dir"] != nil {
                    if let previous { setenv("AILBUM_MODELS_DIR", previous, 1) } else { unsetenv("AILBUM_MODELS_DIR") }
                }
            }
            for name in modelNames {
                out("\(name)\t\(ModelStore.available(name) ? "доступна" : "отсутствует")")
            }
            return 0
        case "compare":
            let p = try parse(rest, valueOptions: [
                "--photo-hash-distance": "photo-hash-distance", "--photo-hist-similarity": "photo-hist-similarity",
                "--photo-geometric-similarity": "photo-geometric-similarity",
                "--geometric-max-features": "geometric-max-features", "--max-image-side": "max-image-side",
            ], flagOptions: [:])
            try exactly(p, ["left", "right"])
            out(dump(try Compare.images(
                left: p.positionals[0], right: p.positionals[1],
                hashDistance: try p.int("photo-hash-distance", 12),
                histogramThreshold: try p.double("photo-hist-similarity", 0.72),
                geometricThreshold: try p.double("photo-geometric-similarity", 0.55),
                geometricMaxFeatures: try p.int("geometric-max-features", 4000),
                maxImageSide: try p.int("max-image-side", 1600))))
            return 0
        case "evaluate", "evaluate-stories":
            let p = try parse(rest, valueOptions: dbOption.merging(["--run-id": "run-id"]) { a, _ in a }, flagOptions: [:])
            try exactly(p, ["annotations"])
            out(dump(try StoryEvaluation.evaluateDatabase(
                database: p.string("database", defaultDatabase), annotations: p.positionals[0], runId: p.values["run-id"])))
            return 0
        default: return nil
        }
    }

    // MARK: handlers

    static func analyze(_ args: [String], out: (String) -> Void) throws -> Int32 {
        let numeric = [
            "sharpness-threshold", "photo-hash-distance", "photo-hist-similarity", "photo-geometric-similarity",
            "geometric-max-features", "geometric-neighbor-window", "geometric-time-window-minutes",
            "face-similarity", "min-face-size", "min-attribute-face-size", "face-backend", "semantic-backend",
            "clip-model", "semantic-threshold", "semantic-top-k", "semantic-batch-size", "semantic-device",
            "story-gap-minutes", "story-continuity-minutes", "story-max-duration-hours",
            "story-semantic-break-minutes", "story-naming-backend", "lmstudio-url", "lmstudio-model",
            "story-vlm-images", "story-vlm-timeout", "models-dir", "feature-cache-dir", "database",
        ]
        var valueOptions = Dictionary(uniqueKeysWithValues: numeric.map { ("--" + $0, $0) })
        valueOptions["-o"] = "output"
        valueOptions["--output"] = "output"
        let p = try parse(args, valueOptions: valueOptions, flagOptions: [
            "--no-recursive": "no-recursive", "--no-geometric-similarity": "no-geometric-similarity",
            "--no-feature-cache": "no-feature-cache", "--quiet": "quiet",
        ])
        try exactly(p, ["source"])
        let source = p.positionals[0]
        let output = p.string("output", "output")
        let database = p.string("database", defaultDatabase)
        var c = PipelineConfig()
        c.sharpnessThreshold = try p.double("sharpness-threshold", 100.0)
        c.photoHashDistance = try p.int("photo-hash-distance", 12)
        c.photoHistSimilarity = try p.double("photo-hist-similarity", 0.72)
        c.photoGeometricSimilarity = p.flags.contains("no-geometric-similarity")
            ? nil : try p.double("photo-geometric-similarity", 0.55)
        c.geometricMaxFeatures = try p.int("geometric-max-features", 4000)
        c.geometricNeighborWindow = try p.int("geometric-neighbor-window", 12)
        c.geometricTimeWindowMinutes = try p.int("geometric-time-window-minutes", 15)
        c.faceSimilarity = p.values["face-similarity"] == nil ? nil : try p.double("face-similarity", 0)
        c.minFaceSize = try p.int("min-face-size", 40)
        c.minAttributeFaceSize = try p.int("min-attribute-face-size", 64)
        c.faceBackend = try p.choice("face-backend", "auto", ["auto", "classic", "dnn"])
        c.semanticBackend = try p.choice("semantic-backend", "auto", ["auto", "clip", "off"])
        c.clipModel = p.string("clip-model", "openai/clip-vit-base-patch32")
        c.semanticThreshold = try p.double("semantic-threshold", 0.15)
        c.semanticTopK = try p.int("semantic-top-k", 3)
        c.semanticBatchSize = try p.int("semantic-batch-size", 8)
        c.semanticDevice = try p.choice("semantic-device", "auto", ["auto", "cpu", "mps", "cuda"])
        c.storyGapMinutes = try p.int("story-gap-minutes", 120)
        c.storyContinuityMinutes = try p.int("story-continuity-minutes", 360)
        c.storyMaxDurationHours = try p.int("story-max-duration-hours", 12)
        c.storySemanticBreakMinutes = try p.int("story-semantic-break-minutes", 30)
        c.storyNamingBackend = try p.choice("story-naming-backend", "auto", ["auto", "rules", "lmstudio"])
        c.lmstudioUrl = p.string("lmstudio-url", "http://127.0.0.1:1234/v1")
        c.lmstudioModel = p.string("lmstudio-model", "qwen/qwen3-vl-2b")
        c.storyVlmImages = try p.int("story-vlm-images", 4)
        c.storyVlmTimeout = try p.double("story-vlm-timeout", 90.0)
        c.modelsDir = URL(fileURLWithPath: p.string("models-dir", "models"))
        c.featureCache = !p.flags.contains("no-feature-cache")
        c.featureCacheDir = p.values["feature-cache-dir"].map { URL(fileURLWithPath: $0) }

        let recursive = !p.flags.contains("no-recursive")
        let quiet = p.flags.contains("quiet")
        let run = analyzeOverride ?? { s, o, cfg, r, pr, d in
            try Pipeline.analyzeLibrary(source: s, output: o, config: cfg, recursive: r, progress: pr, database: d)
        }
        let manifest = try withoutActuallyEscaping(out) { emit in
            try run(source, output, c, recursive, quiet ? nil : { emit($0) }, database)
        }
        out(dump(manifest["summary"] ?? .null))
        let db = try Database.open(path: database)
        let runId = manifest["run_id"]?.stringValue ?? ""
        let albumId = try Albums.attachRun(db, runId: runId, sources: [Catalog.resolve(source)])
        out("Альбом: \(albumId)")
        out("Результаты: \(Catalog.resolve(output + "/analysis.json"))")
        out("База данных: \(Catalog.resolve(database))")
        return 0
    }

    static func index(_ args: [String], out: (String) -> Void) throws -> Int32 {
        let p = try parse(args, valueOptions: ["--database": "database"],
                          flagOptions: ["--no-recursive": "no-recursive", "--quiet": "quiet"])
        try exactly(p, ["source"])
        let source = p.positionals[0]
        let database = p.string("database", defaultDatabase)
        let recursive = !p.flags.contains("no-recursive")
        let quiet = p.flags.contains("quiet")
        let summary = try withoutActuallyEscaping(out) { emit -> JSONValue in
            var progress: ((Int, Int) -> Void)?
            if !quiet {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: source, isDirectory: &isDir)
            let base = isDir.boolValue ? source : (source as NSString).deletingLastPathComponent
            let prefix = base.hasSuffix("/") ? base : base + "/"
            let paths = Catalog.discoverImages(source, recursive: recursive)
            progress = { i, n in
                let path = paths.indices.contains(i - 1) ? paths[i - 1] : ""
                emit("[\(i)/\(n)] \(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)")
            }
            }
            return try Catalog.indexLibrary(source: source, database: database, recursive: recursive, progress: progress)
        }
        out(dump(summary))
        out("База данных: \(Catalog.resolve(database))")
        return 0
    }

    static func database(_ sub: String, _ args: [String], out: (String) -> Void) throws -> Int32 {
        let p = try parse(args, valueOptions: ["--database": "database", "--limit": "limit"],
                          flagOptions: ["--json": "json"])
        let database = p.string("database", defaultDatabase)
        switch sub {
        case "stats":
            try exactly(p, [])
            out(dump(try CatalogQueries.summary(database: database)))
        case "show":
            try exactly(p, ["image_id"])
            out(dump(try CatalogQueries.getImage(database: database, imageId: try positionalInt(p.positionals[0], "image_id"))))
        default:
            try exactly(p, [])
            let images = try CatalogQueries.listImages(database: database, limit: try p.int("limit", 100))
            if p.flags.contains("json") {
                out(dump(images))
            } else {
                out("ID\tДата съёмки\tРазмер\tКамера\tПуть")
                for image in images.arrayValue ?? [] {
                    let dimensions = "\(text(image["width"]))x\(text(image["height"]))"
                    let camera = [image["camera_make"], image["camera_model"]]
                        .compactMap { $0?.stringValue }.filter { !$0.isEmpty }.joined(separator: " ")
                    let taken = image["taken_at"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
                    out("\(text(image["id"]))\t\(taken)\t\(dimensions)\t\(camera.isEmpty ? "-" : camera)\t\(text(image["path"]))")
                }
            }
        }
        return 0
    }

    /// Python `str()` of a scalar JSON value.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s)?: return s
        case .int(let i)?: return String(i)
        case .double(let d)?: return String(d)
        case .bool(let b)?: return b ? "True" : "False"
        default: return "None"
        }
    }

    static func people(_ sub: String, _ args: [String], out: (String) -> Void) throws -> Int32 {
        let p = try parse(args, valueOptions: [
            "--database": "database", "--limit": "limit", "--output": "output",
            "--face-size": "face-size", "--columns": "columns",
        ], flagOptions: ["--json": "json"])
        let database = p.string("database", defaultDatabase)
        let result: JSONValue
        switch sub {
        case "list":
            try exactly(p, [])
            let found = try PeopleStore.list(database: database, limit: try p.int("limit", 100))
            if p.flags.contains("json") {
                out(dump(found))
            } else {
                out("ID\tИмя\tЛица\tФото\tМодель")
                for person in found.arrayValue ?? [] {
                    let name = person["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
                    out("\(text(person["id"]))\t\(name)\t\(text(person["face_count"]))\t\(text(person["photo_count"]))\t\(text(person["embedding_model"]))")
                }
            }
            return 0
        case "show":
            try exactly(p, ["person_id"])
            result = try PeopleStore.get(database: database, personId: try positionalInt(p.positionals[0], "person_id"))
        case "name":
            try exactly(p, ["person_id", "name"])
            result = try PeopleStore.name(
                database: database, personId: try positionalInt(p.positionals[0], "person_id"), name: p.positionals[1])
        case "merge":
            if p.positionals.count < 2 {
                throw AilbumError.invalid("the following arguments are required: \(["target_id", "source_ids"][p.positionals.count...].joined(separator: ", "))")
            }
            result = try PeopleStore.merge(
                database: database, targetId: try positionalInt(p.positionals[0], "target_id"),
                sourceIds: try p.positionals.dropFirst().map { try positionalInt($0, "source_ids") })
        default:
            try exactly(p, ["person_id"])
            let id = try positionalInt(p.positionals[0], "person_id")
            result = try PeopleStore.composeSheet(
                database: database, personId: id, output: p.values["output"] ?? "output/people/person-\(id).jpg",
                faceSize: try p.int("face-size", 180), columns: try p.int("columns", 5))
        }
        out(dump(result))
        return 0
    }
}
