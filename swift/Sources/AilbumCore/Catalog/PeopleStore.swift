import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Port of the people functions of database.py (882-1135) and people.py.
public enum PeopleStore {
    private static func openExisting(_ database: String) throws -> Database {
        guard FileManager.default.fileExists(atPath: database) else {
            throw AilbumError.invalid("Database does not exist: \(database)")
        }
        return try Database.open(path: database)
    }

    private static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func text(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }

    private static func faceResult(_ row: [String: SQLValue]) -> JSONValue {
        var object = JSONValue.row(row).objectValue ?? [:]
        let scores = object.removeValue(forKey: "expression_scores_json")
        if let raw = scores?.stringValue, !raw.isEmpty,
           let parsed = try? JSONValue.parse(raw) {
            object["expression_scores"] = parsed
        } else {
            object["expression_scores"] = .null
        }
        if let both = object["both_eyes_open"]?.intValue { object["both_eyes_open"] = .bool(both != 0) }
        return .object(object)
    }

    public static func list(database: String, limit: Int) throws -> JSONValue {
        let db = try openExisting(database)
        let rows = try db.query(
            """
            SELECT p.id, p.public_id, p.name, p.embedding_model,
                   COUNT(f.id) AS face_count,
                   COUNT(DISTINCT f.image_id) AS photo_count,
                   p.created_at, p.updated_at
            FROM people AS p
            LEFT JOIN faces AS f ON f.person_id = p.id
            GROUP BY p.id
            ORDER BY photo_count DESC, face_count DESC, p.id
            LIMIT ?
            """, [.integer(limit)])
        return .array(rows.map { JSONValue.row($0) })
    }

    public static func get(database: String, personId: Int) throws -> JSONValue {
        let db = try openExisting(database)
        return try get(db, personId: personId)
    }

    private static func get(_ db: Database, personId: Int) throws -> JSONValue {
        let rows = try db.query(
            """
            SELECT p.id, p.public_id, p.name, p.embedding_model,
                   p.embedding_dim, p.created_at, p.updated_at,
                   COUNT(f.id) AS face_count,
                   COUNT(DISTINCT f.image_id) AS photo_count
            FROM people AS p
            LEFT JOIN faces AS f ON f.person_id = p.id
            WHERE p.id = ?
            GROUP BY p.id
            """, [.integer(personId)])
        guard let row = rows.first else { throw AilbumError.invalid("Person id does not exist: \(personId)") }
        var result = JSONValue.row(row).objectValue ?? [:]
        let faces = try db.query(
            """
            SELECT f.id, f.run_id, f.face_id, f.face_index, f.image_id,
                   f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                   f.confidence, f.person_cluster, f.embedding_model,
                   f.left_eye_state, f.right_eye_state,
                   f.left_eye_open_probability, f.right_eye_open_probability,
                   f.both_eyes_open, f.expression, f.expression_confidence,
                   f.smile_probability, f.expression_scores_json,
                   i.path, i.taken_at, i.width AS image_width,
                   i.height AS image_height
            FROM faces AS f
            JOIN images AS i ON i.id = f.image_id
            WHERE f.person_id = ?
            ORDER BY COALESCE(i.taken_at, i.modified_at), i.path, f.face_index
            """, [.integer(personId)])
        result["faces"] = .array(faces.map(faceResult))
        return .object(result)
    }

    public static func name(database: String, personId: Int, name: String?) throws -> JSONValue {
        let db = try Database.open(path: database)
        try db.transaction {
            try db.execute("UPDATE people SET name = ?, updated_at = ? WHERE id = ?",
                           [text(normalized(name)), .text(Catalog.utcNow()), .integer(personId)])
            if (try db.query("SELECT changes() AS c", []).first?["c"]) == .integer(0) {
                throw AilbumError.invalid("Person id does not exist: \(personId)")
            }
        }
        return try get(db, personId: personId)
    }

    public static func merge(database: String, targetId: Int, sourceIds: [Int]) throws -> JSONValue {
        let sources = Set(sourceIds).subtracting([targetId]).sorted()
        if sources.isEmpty { throw AilbumError.invalid("At least one different source person is required") }
        let db = try Database.open(path: database)
        try db.transaction {
            let targets = try db.query("SELECT id, name, embedding_model FROM people WHERE id = ?",
                                       [.integer(targetId)])
            guard let target = targets.first else {
                throw AilbumError.invalid("Person id does not exist: \(targetId)")
            }
            let marks = sources.map { _ in "?" }.joined(separator: ", ")
            let args = sources.map { SQLValue.integer($0) }
            let rows = try db.query(
                "SELECT id, name, embedding_model FROM people WHERE id IN (\(marks)) ORDER BY id", args)
            let found = Set(rows.compactMap { $0["id"]?.integerInt })
            let missing = Set(sources).subtracting(found).sorted()
            if !missing.isEmpty {
                throw AilbumError.invalid("Person ids do not exist: [\(missing.map(String.init).joined(separator: ", "))]")
            }
            if rows.contains(where: { $0["embedding_model"] != target["embedding_model"] }) {
                throw AilbumError.invalid("Нельзя объединить людей из разных моделей признаков")
            }
            let inherited = rows.compactMap { row -> String? in
                if case .text(let n)? = row["name"], !n.isEmpty { return n }
                return nil
            }.first
            var targetHasName = false
            if case .text(let n)? = target["name"], !n.isEmpty { targetHasName = true }
            if !targetHasName, let inherited {
                try db.execute("UPDATE people SET name = ?, updated_at = ? WHERE id = ?",
                               [.text(inherited), .text(Catalog.utcNow()), .integer(targetId)])
            }
            try db.execute("UPDATE faces SET person_id = ? WHERE person_id IN (\(marks))",
                           [.integer(targetId)] + args)
            try db.execute("DELETE FROM people WHERE id IN (\(marks))", args)
            try AnalysisStore.refreshCentroid(db, personId: targetId)
        }
        return try get(db, personId: targetId)
    }

    public static func desktopPeople(database: String) throws -> JSONValue {
        let db = try openExisting(database)
        let people = try db.query(
            """
            SELECT p.id, p.public_id, p.name, p.embedding_model,
                   COUNT(f.id) AS face_count,
                   COUNT(DISTINCT f.image_id) AS photo_count,
                   MIN(f.id) AS cover_face_id
            FROM people AS p
            LEFT JOIN faces AS f ON f.person_id = p.id
            GROUP BY p.id
            ORDER BY (COUNT(f.id) = 0), photo_count DESC, face_count DESC, p.id
            """, [])
        let unassigned = try db.query("SELECT COUNT(*) AS c FROM faces WHERE person_id IS NULL", [])
        let total = try db.query("SELECT COUNT(*) AS c FROM faces", [])
        return [
            "database": .string(Catalog.resolve(database)),
            "people": .array(people.map { JSONValue.row($0) }),
            "unassigned_count": .int(unassigned.first?["c"]?.integerInt ?? 0),
            "total_faces": .int(total.first?["c"]?.integerInt ?? 0),
        ]
    }

    public static func desktopFaces(database: String, personId: Int?) throws -> JSONValue {
        let db = try openExisting(database)
        var owner = JSONValue.null
        var predicate = "f.person_id IS NULL"
        var args: [SQLValue] = []
        if let personId {
            let rows = try db.query(
                "SELECT id, public_id, name, embedding_model FROM people WHERE id = ?", [.integer(personId)])
            guard let row = rows.first else { throw AilbumError.invalid("Person id does not exist: \(personId)") }
            owner = JSONValue.row(row)
            predicate = "f.person_id = ?"
            args = [.integer(personId)]
        }
        let faces = try db.query(
            """
            SELECT f.id, f.run_id, f.face_id, f.face_index, f.image_id,
                   f.bbox_x, f.bbox_y, f.bbox_width, f.bbox_height,
                   f.confidence, f.person_id, f.embedding_model,
                   f.left_eye_state, f.right_eye_state, f.both_eyes_open,
                   f.expression, f.expression_confidence, f.smile_probability,
                   f.expression_scores_json, i.path, i.file_name, i.taken_at,
                   i.orientation
            FROM faces AS f
            JOIN images AS i ON i.id = f.image_id
            WHERE \(predicate)
            ORDER BY COALESCE(i.taken_at, i.modified_at) DESC, i.path, f.face_index
            """, args)
        return ["person": owner, "faces": .array(faces.map(faceResult))]
    }

    public static func setFacePerson(database: String, faceId: Int, personId: Int?) throws -> JSONValue {
        let db = try Database.open(path: database)
        try db.transaction {
            let faces = try db.query("SELECT id, person_id, embedding_model FROM faces WHERE id = ?",
                                     [.integer(faceId)])
            guard let face = faces.first else { throw AilbumError.invalid("Face id does not exist: \(faceId)") }
            let oldPerson = face["person_id"]?.integerInt
            if let personId {
                let people = try db.query("SELECT id, embedding_model FROM people WHERE id = ?",
                                          [.integer(personId)])
                guard let person = people.first else {
                    throw AilbumError.invalid("Person id does not exist: \(personId)")
                }
                if face["embedding_model"] != person["embedding_model"] {
                    throw AilbumError.invalid("Нельзя связать лицо и человека из разных моделей признаков")
                }
            }
            try db.execute("UPDATE faces SET person_id = ? WHERE id = ?",
                           [personId.map { .integer($0) } ?? .null, .integer(faceId)])
            for affected in Set([oldPerson, personId].compactMap { $0 }).sorted() {
                try AnalysisStore.refreshCentroid(db, personId: affected)
            }
        }
        return ["face_id": .int(faceId), "person_id": personId.map { .int($0) } ?? .null]
    }

    public static func createPersonFromFace(database: String, faceId: Int, name: String?) throws -> JSONValue {
        let db = try Database.open(path: database)
        var personId = 0
        try db.transaction {
            let faces = try db.query(
                "SELECT id, person_id, embedding, embedding_dim, embedding_model FROM faces WHERE id = ?",
                [.integer(faceId)])
            guard let face = faces.first else { throw AilbumError.invalid("Face id does not exist: \(faceId)") }
            guard let embedding = face["embedding"], embedding != .null,
                  let dim = face["embedding_dim"], dim != .null,
                  case .text(let model)? = face["embedding_model"], !model.isEmpty else {
                throw AilbumError.invalid("У лица нет признаков, необходимых для создания человека")
            }
            let oldPerson = face["person_id"]?.integerInt
            let now = Catalog.utcNow()
            try db.execute(
                """
                INSERT INTO people (
                    public_id, name, embedding_model, centroid_embedding,
                    embedding_dim, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(UUID().uuidString.lowercased()), text(normalized(name)), .text(model), embedding, dim,
                 .text(now), .text(now)])
            personId = try db.query("SELECT last_insert_rowid() AS id", []).first?["id"]?.integerInt ?? 0
            try db.execute("UPDATE faces SET person_id = ? WHERE id = ?", [.integer(personId), .integer(faceId)])
            if let oldPerson { try AnalysisStore.refreshCentroid(db, personId: oldPerson) }
        }
        return try get(db, personId: personId)
    }

    // MARK: contact sheet

    public static func composeSheet(database: String, personId: Int, output: String,
                                    faceSize: Int, columns: Int) throws -> JSONValue {
        if faceSize < 32 { throw AilbumError.invalid("Face size must be at least 32 pixels") }
        if columns < 1 { throw AilbumError.invalid("Columns must be at least 1") }
        let person = try get(database: database, personId: personId)
        var unique: [JSONValue] = []
        var seen = Set<[String]>()
        for face in person["faces"]?.arrayValue ?? [] {
            let key = ["path", "bbox_x", "bbox_y", "bbox_width", "bbox_height"].map { k -> String in
                let v = face[k]
                return v?.stringValue ?? v?.intValue.map(String.init) ?? ""
            }
            if seen.insert(key).inserted { unique.append(face) }
        }
        if unique.isEmpty { throw AilbumError.invalid("Person \(personId) has no faces") }

        let gap = 8, header = 42
        let rows = (unique.count + columns - 1) / columns
        let width = columns * faceSize + (columns + 1) * gap
        let height = header + rows * faceSize + (rows + 1) * gap
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AilbumError.decode("не удалось создать контекст")
        }
        ctx.setFillColor(CGColor(srgbRed: 28 / 255, green: 30 / 255, blue: 34 / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let title = person["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Person \(personId)"
        let attributed = NSAttributedString(string: "\(title) · \(unique.count) faces", attributes: [
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
        ])
        ctx.textPosition = CGPoint(x: gap, y: height - 12 - 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)

        for (index, face) in unique.enumerated() {
            let tile = try faceTile(face, size: faceSize)
            let x = gap + (index % columns) * (faceSize + gap)
            let y = header + gap + (index / columns) * (faceSize + gap)
            ctx.draw(tile, in: CGRect(x: x, y: height - y - faceSize, width: faceSize, height: faceSize))
        }

        guard let sheet = ctx.makeImage() else { throw AilbumError.decode("не удалось создать изображение") }
        try FileManager.default.createDirectory(
            atPath: (output as NSString).deletingLastPathComponent.isEmpty ? "." : (output as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: output) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw AilbumError.decode("не удалось записать файл: \(output)")
        }
        CGImageDestinationAddImage(destination, sheet,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AilbumError.decode("не удалось записать файл: \(output)")
        }
        return [
            "person_id": .int(personId),
            "name": person["name"] ?? .null,
            "faces": .int(unique.count),
            "output": .string(Catalog.resolve(output)),
        ]
    }

    private static func faceTile(_ face: JSONValue, size: Int) throws -> CGImage {
        let image = try ImageLoader.load(path: face["path"]?.stringValue ?? "")
        var rgbx = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            rgbx[i * 4] = image.pixels[i * 3]
            rgbx[i * 4 + 1] = image.pixels[i * 3 + 1]
            rgbx[i * 4 + 2] = image.pixels[i * 3 + 2]
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let full: CGImage? = rgbx.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: image.width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        let x = face["bbox_x"]?.intValue ?? 0, y = face["bbox_y"]?.intValue ?? 0
        let w = face["bbox_width"]?.intValue ?? 0, h = face["bbox_height"]?.intValue ?? 0
        let margin = Int((Double(max(w, h)) * 0.2).rounded(.toNearestOrEven))
        let x0 = max(0, x - margin), y0 = max(0, y - margin)
        let x1 = min(image.width, x + w + margin), y1 = min(image.height, y + h + margin)
        guard let full, x1 > x0, y1 > y0,
              let crop = full.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AilbumError.decode("не удалось вырезать лицо") }
        // ImageOps.fit: scale to cover, centre crop
        let scale = max(Double(size) / Double(crop.width), Double(size) / Double(crop.height))
        let dw = Double(crop.width) * scale, dh = Double(crop.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: (Double(size) - dw) / 2, y: (Double(size) - dh) / 2, width: dw, height: dh))
        guard let tile = ctx.makeImage() else { throw AilbumError.decode("не удалось вырезать лицо") }
        return tile
    }
}

private extension SQLValue {
    var integerInt: Int? {
        if case .integer(let v) = self { return Int(v) }
        return nil
    }
}
