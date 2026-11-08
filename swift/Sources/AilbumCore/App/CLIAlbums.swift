import Foundation

/// Port of the album / forget / ranking / db usage handlers of src/ailbum/cli.py.
public enum CLIAlbums {
    static let defaultDatabase = ".ailbum/ailbum.sqlite3"

    // Test seams; nil means the real implementation.
    nonisolated(unsafe) static var prepareOverride: ((String, Int) throws -> JSONValue)?
    nonisolated(unsafe) static var trashOverride: (([String]) -> [String])?
    nonisolated(unsafe) static var completeOverride: ((String, Int, [String]) throws -> JSONValue)?
    nonisolated(unsafe) static var planForgetOverride: ((String, Int?, String?) throws -> JSONValue)?
    nonisolated(unsafe) static var forgetOverride: ((String, Int?, String?) throws -> JSONValue)?
    nonisolated(unsafe) static var usageOverride: ((String) throws -> JSONValue)?

    private struct Parsed {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
    }

    private static func parse(_ args: [String], valueOptions: Set<String>, flagOptions: Set<String>) throws -> Parsed {
        var p = Parsed()
        var i = 0
        while i < args.count {
            let a = args[i]
            if valueOptions.contains(a) {
                guard i + 1 < args.count else { throw AilbumError.invalid("argument \(a): expected one argument") }
                p.values[a] = args[i + 1]
                i += 2
            } else if flagOptions.contains(a) {
                p.flags.insert(a)
                i += 1
            } else if a.hasPrefix("-") && a.count > 1 && Int(a) == nil {
                throw AilbumError.invalid("unrecognized arguments: \(a)")
            } else {
                p.positional.append(a)
                i += 1
            }
        }
        return p
    }

    private static func intArg(_ text: String, _ name: String) throws -> Int {
        guard let v = Int(text) else { throw AilbumError.invalid("argument \(name): invalid int value: '\(text)'") }
        return v
    }

    // MARK: json.dumps(ensure_ascii=False, indent=2), keys sorted

    private static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if u.value < 0x20 { r += String(format: "\\u%04x", u.value) } else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\""
    }

    static func pretty(_ value: JSONValue, indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent + 2)
        let end = String(repeating: " ", count: indent)
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return v == v.rounded() && abs(v) < 1e16 ? String(format: "%.1f", v) : "\(v)"
        case .string(let s): return quote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + pretty($0, indent: indent + 2) }.joined(separator: ",\n") + "\n" + end + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let items = o.keys.sorted().map { pad + quote($0) + ": " + pretty(o[$0]!, indent: indent + 2) }
            return "{\n" + items.joined(separator: ",\n") + "\n" + end + "}"
        }
    }

    // MARK: entry

    public static func run(_ args: [String], out: (String) -> Void, input: () -> String?) throws -> Int32? {
        guard let command = args.first else { return nil }
        let rest = Array(args.dropFirst())
        switch command {
        case "album": return try album(rest, out: out, input: input)
        case "forget": return try forgetCommand(rest, out: out)
        case "ranking": return try ranking(rest, out: out)
        case "db":
            guard rest.first == "usage" else { return nil }
            return try usageCommand(Array(rest.dropFirst()), out: out)
        default: return nil
        }
    }

    private static func album(_ args: [String], out: (String) -> Void, input: () -> String?) throws -> Int32 {
        guard let sub = args.first else { throw AilbumError.invalid("the following arguments are required: album_command") }
        let rest = Array(args.dropFirst())
        let known: Set<String> = ["list", "show", "order", "reopen", "delete", "archive", "export"]
        guard known.contains(sub) else { throw AilbumError.invalid("argument album_command: invalid choice: '\(sub)'") }
        var flags: Set<String> = []
        var values: Set<String> = ["--database"]
        if sub == "list" { flags.insert("--json") }
        if sub == "delete" { flags.insert("--forget-decisions") }
        if sub == "archive" { flags.insert("--yes") }
        if sub == "export" { values.insert("--folder") }
        let p = try parse(rest, valueOptions: values, flagOptions: flags)
        let db = p.values["--database"] ?? defaultDatabase
        var albumId = 0
        if sub != "list" {
            guard p.positional.count == 1 else { throw AilbumError.invalid("the following arguments are required: album_id") }
            albumId = try intArg(p.positional[0], "album_id")
        } else if !p.positional.isEmpty {
            throw AilbumError.invalid("unrecognized arguments: \(p.positional.joined(separator: " "))")
        }

        if sub == "archive" { return try archive(db, albumId, yes: p.flags.contains("--yes"), out: out, input: input) }
        if sub == "export" {
            guard let folder = p.values["--folder"] else { throw AilbumError.invalid("the following arguments are required: --folder") }
            out(pretty(try LayoutExport.exportOriginals(database: db, albumId: albumId, folder: folder)))
            return 0
        }
        let conn = try Database.open(path: db)
        switch sub {
        case "list":
            let found = try Albums.list(conn)
            if p.flags.contains("--json") { out(pretty(found)); return 0 }
            out("ID\tСтатус\tНазвание\tФото")
            for item in found.arrayValue ?? [] {
                let id = item["id"]?.intValue ?? 0
                let status = item["status"]?.stringValue ?? ""
                let title = item["title"]?.stringValue ?? ""
                let count = item["photo_count"]?.intValue ?? 0
                let target = item["target_count"]?.intValue ?? 0
                out("\(id)\t\(status)\t\(title)\t\(count)/\(target)")
            }
        case "show": out(pretty(try Albums.get(conn, albumId)))
        case "order": out(pretty(try Albums.setStatus(conn, albumId, "ordered")))
        case "reopen": out(pretty(try Albums.setStatus(conn, albumId, "draft")))
        default:
            try Albums.delete(conn, albumId, forgetDecisions: p.flags.contains("--forget-decisions"))
            out("Альбом \(albumId) удалён")
        }
        return 0
    }

    private static func archive(_ db: String, _ albumId: Int, yes: Bool, out: (String) -> Void, input: () -> String?) throws -> Int32 {
        let plan = try (prepareOverride ?? { try Archive.prepare(database: $0, albumId: $1) })(db, albumId)
        for item in plan["blocked"]?.arrayValue ?? [] {
            out("Не удаляем фото \(item["image_id"]?.intValue ?? 0): \(item["reason"]?.stringValue ?? "")")
        }
        if plan["needs_export"]?.boolValue == true {
            out("Нужен экспорт: сначала выполните ailbum album export \(albumId) --folder ПАПКА")
            return 1
        }
        let paths = (plan["trash"]?.arrayValue ?? []).compactMap { $0.stringValue }
        if !paths.isEmpty && !yes {
            out("Перенести \(paths.count) файлов в Корзину? [y/N] ")
            let answer = (input() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !["y", "yes", "д", "да"].contains(answer) {
                out("Отменено")
                return 0
            }
        }
        let trashed = paths.isEmpty ? [] : (trashOverride ?? Archive.trashPaths)(paths)
        out(pretty(try (completeOverride ?? { try Archive.complete(database: $0, albumId: $1, trashed: $2) })(db, albumId, trashed)))
        return 0
    }

    private static func forgetCommand(_ args: [String], out: (String) -> Void) throws -> Int32 {
        let p = try parse(args, valueOptions: ["--album", "--source", "--database"], flagOptions: ["--yes"])
        if !p.positional.isEmpty { throw AilbumError.invalid("unrecognized arguments: \(p.positional.joined(separator: " "))") }
        let albumText = p.values["--album"], source = p.values["--source"]
        if albumText == nil && source == nil { throw AilbumError.invalid("one of the arguments --album --source is required") }
        if albumText != nil && source != nil { throw AilbumError.invalid("argument --source: not allowed with argument --album") }
        let albumId = try albumText.map { try intArg($0, "--album") }
        let db = p.values["--database"] ?? defaultDatabase
        out(pretty(try (planForgetOverride ?? { try Forget.plan(database: $0, albumId: $1, source: $2) })(db, albumId, source)))
        if p.flags.contains("--yes") {
            out(pretty(try (forgetOverride ?? { try Forget.forget(database: $0, albumId: $1, source: $2) })(db, albumId, source)))
        } else {
            out("Это только план. Добавьте --yes, чтобы выполнить.")
        }
        return 0
    }

    private static func ranking(_ args: [String], out: (String) -> Void) throws -> Int32 {
        guard let sub = args.first else { throw AilbumError.invalid("the following arguments are required: ranking_command") }
        guard ["train", "status", "evaluate"].contains(sub) else {
            throw AilbumError.invalid("argument ranking_command: invalid choice: '\(sub)'")
        }
        let p = try parse(Array(args.dropFirst()), valueOptions: ["--database"], flagOptions: [])
        if !p.positional.isEmpty { throw AilbumError.invalid("unrecognized arguments: \(p.positional.joined(separator: " "))") }
        let conn = try Database.open(path: p.values["--database"] ?? defaultDatabase)
        switch sub {
        case "train": out(pretty(try RankingTrain.train(conn)))
        case "status": out(pretty(try RankingTrain.status(conn)))
        default: out(pretty(try RankingTrain.evaluate(conn)))
        }
        return 0
    }

    private static func usageCommand(_ args: [String], out: (String) -> Void) throws -> Int32 {
        let p = try parse(args, valueOptions: ["--database"], flagOptions: [])
        if !p.positional.isEmpty { throw AilbumError.invalid("unrecognized arguments: \(p.positional.joined(separator: " "))") }
        let db = p.values["--database"] ?? defaultDatabase
        let data = try (usageOverride ?? { try Forget.usage(database: $0) })(db)
        func mb(_ key: String) -> String {
            String(format: "%.1f", Double(data[key]?.intValue ?? 0) / Double(1024 * 1024))
        }
        out("База данных: \(mb("database_bytes")) МБ")
        out("Превью: \(mb("proxies_bytes")) МБ")
        out("Кэш признаков: \(mb("feature_cache_bytes")) МБ")
        let images = data["images"] ?? .null
        out("Оригиналы: на месте \(images["present"]?.intValue ?? 0), нет файла \(images["missing"]?.intValue ?? 0), в архиве \(images["archived"]?.intValue ?? 0)")
        return 0
    }
}
