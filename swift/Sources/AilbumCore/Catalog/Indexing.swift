import Foundation

public enum Catalog {
    static let imageSuffixes: Set<String> = [".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"]

    public static func newRunId() -> String { UUID().uuidString.lowercased() }

    /// Python `datetime.now(timezone.utc).isoformat()`.
    public static func utcNow() -> String {
        let now = Date().timeIntervalSince1970
        let seconds = Int(now.rounded(.down))
        var micros = Int(((now - Double(seconds)) * 1_000_000).rounded(.down))
        if micros < 0 { micros = 0 }
        if micros > 999_999 { micros = 999_999 }
        var t = time_t(seconds)
        var parts = tm()
        gmtime_r(&t, &parts)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(parts.tm_year) + 1900,
                          Int(parts.tm_mon) + 1, Int(parts.tm_mday), Int(parts.tm_hour),
                          Int(parts.tm_min), Int(parts.tm_sec))
        if micros != 0 { text += String(format: ".%06d", micros) }
        return text + "+00:00"
    }

    public static func markSourceMissing(_ db: Database, sourceRoot: String) throws {
        try db.execute(
            "UPDATE images SET availability = 'missing' WHERE source_root = ? AND availability = 'present'",
            [.text(sourceRoot)])
    }

    /// Compact JSON like Python `json.dumps(ensure_ascii=False, separators=(",", ":"))`.
    private static func jsonText(_ value: JSONValue) throws -> String {
        AnalysisStore.json(value)
    }

    private static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    private static func opt(_ v: Int?) -> SQLValue { v.map { .integer($0) } ?? .null }
    private static func opt(_ v: Double?) -> SQLValue { v.map { .real($0) } ?? .null }

    public static func upsertImage(_ db: Database, _ item: ImageMetadata) throws -> Int {
        let values: [(String, SQLValue)] = [
            ("path", .text(item.path)),
            ("source_root", .text(item.sourceRoot)),
            ("relative_path", .text(item.relativePath)),
            ("file_name", .text(item.fileName)),
            ("extension", .text(item.extension)),
            ("file_size_bytes", .integer(item.fileSizeBytes)),
            ("modified_at", .text(item.modifiedAt)),
            ("created_at", opt(item.createdAt)),
            ("sha256", .text(item.sha256)),
            ("mime_type", opt(item.mimeType)),
            ("image_format", opt(item.imageFormat)),
            ("color_mode", opt(item.colorMode)),
            ("width", opt(item.width)),
            ("height", opt(item.height)),
            ("frame_count", opt(item.frameCount)),
            ("orientation", opt(item.orientation)),
            ("taken_at", opt(item.takenAt)),
            ("camera_make", opt(item.cameraMake)),
            ("camera_model", opt(item.cameraModel)),
            ("lens_model", opt(item.lensModel)),
            ("software", opt(item.software)),
            ("gps_latitude", opt(item.gpsLatitude)),
            ("gps_longitude", opt(item.gpsLongitude)),
            ("gps_altitude", opt(item.gpsAltitude)),
            ("extraction_error", opt(item.extractionError)),
            ("exif_json", .text(try jsonText(item.exif))),
            ("container_metadata_json", .text(try jsonText(item.containerMetadata))),
            ("indexed_at", .text(utcNow())),
            ("availability", .text("present")),
        ]
        let columns = values.map(\.0)
        let parameters = values.map(\.1)
        let existing = try db.query("SELECT id FROM images WHERE path = ?", [.text(item.path)])
        if existing.isEmpty {
            let moved = try db.query(
                "SELECT id FROM images WHERE sha256 = ? AND availability IN ('missing', 'archived')",
                [.text(item.sha256)])
            if moved.count == 1, case .integer(let id)? = moved[0]["id"] {
                let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
                try db.execute("UPDATE images SET \(assignments) WHERE id = ?", parameters + [.integer(id)])
                return Int(id)
            }
        }
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let updates = columns.filter { $0 != "path" }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        try db.execute(
            """
            INSERT INTO images (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
            ON CONFLICT(path) DO UPDATE SET \(updates)
            """, parameters)
        let row = try db.query("SELECT id FROM images WHERE path = ?", [.text(item.path)])
        guard case .integer(let id)? = row.first?["id"] else { throw AilbumError.sqlite("upsert lost row") }
        return Int(id)
    }

    static func resolve(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(r) }
        return String(cString: r)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func indexMetadata(database: String, source: String, metadata: [ImageMetadata]) throws -> JSONValue {
        let resolved = resolve(source)
        let sourceRoot = isDirectory(resolved) ? resolved : (resolved as NSString).deletingLastPathComponent
        let db = try Database.open(path: database)
        var counts: [String: SQLValue] = [:]
        try db.transaction {
            try markSourceMissing(db, sourceRoot: sourceRoot)
            for item in metadata { _ = try upsertImage(db, item) }
            counts = try db.query(
                """
                SELECT COUNT(*) AS images,
                       SUM(CASE WHEN availability = 'present' THEN 1 ELSE 0 END) AS available,
                       SUM(CASE WHEN extraction_error IS NOT NULL THEN 1 ELSE 0 END) AS errors
                FROM images
                """, []).first ?? [:]
        }
        var result: [String: JSONValue] = [:]
        for key in ["images", "available", "errors"] {
            if case .integer(let v)? = counts[key] { result[key] = .int(Int(v)) } else { result[key] = .int(0) }
        }
        return .object(result)
    }

    static func discoverImages(_ root: String, recursive: Bool) -> [String] {
        let fm = FileManager.default
        func supported(_ p: String) -> Bool {
            imageSuffixes.contains("." + (p as NSString).pathExtension.lowercased())
        }
        if !isDirectory(root) {
            return fm.fileExists(atPath: root) && supported(root) ? [root] : []
        }
        var found: [String] = []
        if recursive {
            let walker = fm.enumerator(atPath: root)
            while let rel = walker?.nextObject() as? String {
                let full = (root as NSString).appendingPathComponent(rel)
                if !isDirectory(full) && supported(full) { found.append(full) }
            }
        } else {
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let full = (root as NSString).appendingPathComponent(name)
                if !isDirectory(full) && supported(full) { found.append(full) }
            }
        }
        // Python sorts Path objects component by component.
        return found.sorted { ($0 as NSString).pathComponents.lexicographicallyPrecedes(($1 as NSString).pathComponents) }
    }

    public static func indexLibrary(
        source: String, database: String, recursive: Bool = true,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> JSONValue {
        let paths = discoverImages(source, recursive: recursive)
        if paths.isEmpty { throw AilbumError.invalid("No supported images found in \(source)") }
        var metadata: [ImageMetadata] = []
        for (index, path) in paths.enumerated() {
            progress?(index + 1, paths.count)
            metadata.append(try Metadata.collect(path: path, source: source))
        }
        return try indexMetadata(database: database, source: source, metadata: metadata)
    }
}
