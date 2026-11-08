import Foundation

public enum Facts {
    static let faceBackgroundRatio = 0.05
    static let objectConfidence: Float = 0.5
    static let selectedBonus = 0.2
    public static let detectorModel = "yolox_s_2022nov"

    private static func clipRect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Rect? {
        let ax = max(0.0, x0), ay = max(0.0, y0)
        let bx = min(1.0, x1), by = min(1.0, y1)
        if bx - ax <= 0.0 || by - ay <= 0.0 { return nil }
        return Rect(x: ax, y: ay, w: bx - ax, h: by - ay)
    }

    public static func buildRegions(
        faces: [(Double, Double, Double, Double)], objects: [DetectedObject], subject: Rect?
    ) -> [Region] {
        var regions: [Region] = []
        let largest = faces.map { $0.2 * $0.3 }.max() ?? 0.0
        for (x, y, w, h) in faces {
            if w * h <= 0.0 { continue }
            if w * h >= faceBackgroundRatio * largest {
                if let rect = clipRect(x - 0.2 * w, y - 0.35 * h, x + 1.2 * w, y + 1.15 * h) {
                    regions.append(Region(bbox: rect, weight: 1.0, hard: true, kind: "face"))
                }
            } else if let rect = clipRect(x, y, x + w, y + h) {
                regions.append(Region(bbox: rect, weight: 0.2, hard: false, kind: "face_background"))
            }
        }
        for item in objects {
            let isPerson = item.label == "person"
            if !isPerson && item.score < objectConfidence { continue }
            let x = Double(item.bbox[0]), y = Double(item.bbox[1])
            let w = Double(item.bbox[2]), h = Double(item.bbox[3])
            if let rect = clipRect(x, y, x + w, y + h) {
                regions.append(Region(
                    bbox: rect, weight: isPerson ? 0.6 : 0.5, hard: false, kind: isPerson ? "person" : "object"))
            }
        }
        if regions.isEmpty, let subject,
           let rect = clipRect(subject.x, subject.y, subject.x + subject.w, subject.y + subject.h) {
            regions.append(Region(bbox: rect, weight: 0.3, hard: false, kind: "subject"))
        }
        return regions
    }

    private static func number(_ v: SQLValue?) -> Double? {
        switch v {
        case .integer(let i)?: return Double(i)
        case .real(let d)?: return d
        default: return nil
        }
    }

    private static func int(_ v: SQLValue?) -> Int? {
        if case .integer(let i)? = v { return Int(i) }
        return nil
    }

    private static func text(_ v: SQLValue?) -> String? {
        if case .text(let s)? = v { return s }
        return nil
    }

    public static func loadPool(
        _ db: Database, albumId: Int, detector: ((RGBImage) throws -> [DetectedObject])?,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [PhotoFacts] {
        let runId = try LayoutStore.albumRun(db, albumId: albumId)
        let database = text(try db.query("PRAGMA database_list", []).first?["file"]) ?? ""
        let all = try db.query(
            """
            SELECT pa.image_id, pa.quality, pa.aesthetic_score, pa.main_subject_json,
                   pa.similar_cluster, pa.story_id, ps.image_id IS NOT NULL AS selected,
                   i.path, i.sha256, i.availability, i.width, i.height, i.orientation, i.taken_at
            FROM photo_analysis AS pa
            JOIN images AS i ON i.id = pa.image_id
            LEFT JOIN album_photos AS ps ON ps.album_id = ? AND ps.image_id = pa.image_id
            WHERE pa.run_id = ? AND pa.error IS NULL
              AND (ps.image_id IS NOT NULL
                   OR (pa.is_blurry = 0 AND pa.similar_cluster IS NOT NULL
                       AND pa.similar_cluster IN (
                           SELECT pa2.similar_cluster FROM photo_analysis AS pa2
                           JOIN album_photos AS ps2
                             ON ps2.album_id = ? AND ps2.image_id = pa2.image_id
                           WHERE pa2.run_id = pa.run_id AND pa2.similar_cluster IS NOT NULL)))
            ORDER BY pa.image_id
            """,
            [.integer(albumId), .text(runId), .integer(albumId)])
        let rows = all.filter { row in
            (int(row["width"]) ?? 0) != 0 && (int(row["height"]) ?? 0) != 0
                && Proxies.imageSource(database: database, image: row) != nil
        }

        var faces: [Int: [[String: SQLValue]]] = [:]
        for face in try db.query(
            """
            SELECT image_id, bbox_x, bbox_y, bbox_width, bbox_height, both_eyes_open,
                   smile_probability
            FROM faces WHERE run_id = ? ORDER BY image_id, face_index
            """, [.text(runId)]) {
            faces[int(face["image_id"]) ?? 0, default: []].append(face)
        }

        var facts: [PhotoFacts] = []
        let total = rows.count
        for (offset, row) in rows.enumerated() {
            var width = Double(int(row["width"]) ?? 0), height = Double(int(row["height"]) ?? 0)
            if let o = int(row["orientation"]), (5...8).contains(o) { swap(&width, &height) }
            let imageId = int(row["image_id"]) ?? 0
            let imageFaces = faces[imageId] ?? []
            let boxes = imageFaces.map { face in
                ((number(face["bbox_x"]) ?? 0) / width, (number(face["bbox_y"]) ?? 0) / height,
                 (number(face["bbox_width"]) ?? 0) / width, (number(face["bbox_height"]) ?? 0) / height)
            }
            let objects = try objectsFor(db, row: row, detector: detector)
            let regions = buildRegions(faces: boxes, objects: objects, subject: subject(text(row["main_subject_json"])))
            let cluster = int(row["similar_cluster"])
            facts.append(PhotoFacts(
                imageId: imageId, aspect: width / height,
                unitKey: cluster.map { "cluster:\($0)" } ?? "image:\(imageId)",
                storyId: int(row["story_id"]), takenAt: text(row["taken_at"]),
                rank: rank(row, imageFaces), selected: (int(row["selected"]) ?? 0) != 0, regions: regions))
            progress?(offset + 1, total)
        }
        return facts
    }

    private static func subject(_ raw: String?) -> Rect? {
        guard let raw, !raw.isEmpty, let json = try? JSONValue.parse(raw),
              let box = json["bbox"]?.arrayValue, box.count == 4 else { return nil }
        let v = box.compactMap(\.doubleValue)
        guard v.count == 4 else { return nil }
        return Rect(x: v[0], y: v[1], w: v[2], h: v[3])
    }

    private static func rank(_ row: [String: SQLValue], _ faces: [[String: SQLValue]]) -> Double {
        let quality = number(row["quality"]) ?? 0.0
        let aesthetic = number(row["aesthetic_score"]) ?? quality
        var rank = 0.45 * quality + 0.35 * aesthetic
        if !faces.isEmpty {
            let smiling = faces.filter { (number($0["smile_probability"]) ?? 0.0) >= 0.5 }.count
            rank += 0.1 * min(1.0, Double(smiling) / Double(faces.count))
            if faces.contains(where: { number($0["both_eyes_open"]) == 0 }) { rank -= 0.2 }
        }
        if (int(row["selected"]) ?? 0) != 0 { rank += selectedBonus }
        return min(1.0, max(0.0, rank))
    }

    private static func objectsFor(
        _ db: Database, row: [String: SQLValue], detector: ((RGBImage) throws -> [DetectedObject])?
    ) throws -> [DetectedObject] {
        let imageId = int(row["image_id"]) ?? 0
        let cached = try db.query(
            "SELECT sha256, objects_json FROM image_object_scans WHERE image_id = ? AND detector_model = ?",
            [.integer(imageId), .text(detectorModel)]).first
        if let cached, text(cached["sha256"]) == text(row["sha256"]) {
            let items = try JSONValue.parse(text(cached["objects_json"]) ?? "[]").arrayValue ?? []
            return items.map { item in
                let b = (item["bbox"]?.arrayValue ?? []).map { Float($0.doubleValue ?? 0) }
                return DetectedObject(
                    label: item["label"]?.stringValue ?? "", score: Float(item["score"]?.doubleValue ?? 0),
                    bbox: SIMD4<Float>(b.count > 0 ? b[0] : 0, b.count > 1 ? b[1] : 0,
                                       b.count > 2 ? b[2] : 0, b.count > 3 ? b[3] : 0))
            }
        }
        guard let detector, text(row["availability"]) == "present" else { return [] }
        let objects: [DetectedObject]
        do {
            objects = try detector(try ImageLoader.load(path: text(row["path"]) ?? ""))
        } catch {
            return []
        }
        try db.execute(
            """
            INSERT OR REPLACE INTO image_object_scans
            (image_id, detector_model, sha256, objects_json, scanned_at) VALUES (?, ?, ?, ?, ?)
            """,
            [.integer(imageId), .text(detectorModel), .text(text(row["sha256"]) ?? ""),
             .text(dumps(objects)), .text(Catalog.utcNow())])
        return objects
    }

    /// Python `json.dumps` of the object list (default separators, ensure_ascii).
    private static func dumps(_ objects: [DetectedObject]) -> String {
        let items = objects.map { o -> String in
            let box = (0..<4).map { String(Double(o.bbox[$0])) }.joined(separator: ", ")
            return "{\"label\": \(quote(o.label)), \"score\": \(Double(o.score)), \"bbox\": [\(box)]}"
        }
        return "[" + items.joined(separator: ", ") + "]"
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.utf16 {
            switch u {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out += String(UnicodeScalar(UInt8(u)))
            default: out += String(format: "\\u%04x", u)
            }
        }
        return out + "\""
    }
}
