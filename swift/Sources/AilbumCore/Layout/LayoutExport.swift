import Foundation

public enum LayoutExport {
    public static let exportDir = "Раскладка альбома"

    /// Copies the original files of placed photos, named so they sort in album order.
    public static func exportOriginals(database: String, albumId: Int, folder: String) throws -> JSONValue {
        let db = try Database.open(path: database)
        guard let layout = try db.query("SELECT id, selection_hash FROM layouts WHERE album_id = ?", [.integer(albumId)]).first,
              case .integer(let layoutId)? = layout["id"] else {
            throw AilbumError.invalid("Раскладка не создана")
        }
        let rows = try db.query(
            "SELECT s.position, p.cell_index, i.path, i.file_name, i.availability FROM layout_placements p"
            + " JOIN layout_spreads s ON s.id = p.spread_id JOIN images i ON i.id = p.image_id"
            + " WHERE s.layout_id = ? ORDER BY s.position, p.cell_index", [.integer(layoutId)])
        let selectionHash = try AlbumLibrary.selectionHash(db, albumId: albumId)
        let fm = FileManager.default
        let target = unique((folder as NSString).appendingPathComponent(exportDir))
        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        var copied = 0
        var missing: [String] = []
        for row in rows {
            guard case .text(let source)? = row["path"] else { continue }
            guard case .text("present")? = row["availability"] else {
                missing.append(source)
                continue
            }
            var position = 0, cell = 0
            if case .integer(let v)? = row["position"] { position = Int(v) }
            if case .integer(let v)? = row["cell_index"] { cell = Int(v) }
            var fileName = ""
            if case .text(let s)? = row["file_name"] { fileName = s }
            let name = String(format: "%02d", position) + "-\(cell + 1)_" + fileName
            do {
                try fm.copyItem(atPath: source, toPath: (target as NSString).appendingPathComponent(name))
            } catch {
                missing.append(source)
                continue
            }
            copied += 1
        }
        let missingJSON = try dumps(missing)
        try db.execute(
            "INSERT INTO album_exports (album_id, layout_id, selection_hash, folder, count,"
            + " missing_json, exported_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.integer(albumId), .integer(layoutId), .text(selectionHash), .text(target), .integer(copied),
             .text(missingJSON), .text(Catalog.utcNow())])
        guard case .integer(let exportId)? = try db.query("SELECT last_insert_rowid() AS id", []).first?["id"] else {
            throw AilbumError.invalid("Не удалось сохранить выгрузку")
        }
        return ["folder": .string(target), "count": .int(copied),
                "missing": .array(missing.map { .string($0) }), "export_id": .int(Int(exportId))]
    }

    /// Python json.dumps(list_of_str, ensure_ascii=False).
    private static func dumps(_ items: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let parts = try items.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    private static func unique(_ path: String) -> String {
        var candidate = path
        var number = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = path + " \(number)"
            number += 1
        }
        return candidate
    }
}
