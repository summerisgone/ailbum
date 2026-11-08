import Foundation

public enum RankingFeatures {
    public static let version = 1
    public static let names = [
        "quality", "sharpness", "exposure", "aesthetic_score", "has_aesthetic",
        "composition_score", "has_composition", "rule_of_thirds", "color_balance", "color_harmony",
        "crop_risk", "face_count", "closed_eyes_count", "smile_max", "has_smile",
        "known_people_count", "is_blurry", "group_size", "group_rank",
    ]

    private static func vector(
        quality: Double?, sharpness: Double?, exposure: Double?, aesthetic: Double?, composition: Double?,
        thirds: Double?, balance: Double?, harmony: Double?, cropRisk: Double?, faceCount: Int, closed: Int,
        smile: Double?, known: Int, blurry: Bool, groupSize: Int, groupRank: Int
    ) -> [Double] {
        func val(_ x: Double?) -> Double { x ?? 0 }
        func flag(_ x: Double?) -> Double { x == nil ? 0 : 1 }
        return [
            val(quality), val(sharpness), val(exposure),
            val(aesthetic), flag(aesthetic),
            val(composition), flag(composition),
            val(thirds), val(balance), val(harmony), val(cropRisk),
            Double(faceCount), Double(closed), val(smile), flag(smile),
            Double(known), blurry ? 1 : 0, Double(groupSize), Double(groupRank),
        ]
    }

    public static func fromRecord(_ record: PhotoRecord, groupSize: Int, groupRank: Int) -> [Double] {
        let comp = record.composition, color = record.color, sem = record.semantics
        let smiles = record.faces.compactMap { $0.expression?.smileProbability }
        let closed = record.faces.filter { f in
            guard let e = f.eyes else { return false }
            return e.left == "closed" || e.right == "closed"
        }.count
        return vector(
            quality: record.quality, sharpness: record.sharpness, exposure: record.exposure,
            aesthetic: sem?.aestheticScore, composition: comp?.score, thirds: comp?.ruleOfThirds,
            balance: color?.balance, harmony: color?.harmony, cropRisk: comp?.cropRisk,
            faceCount: record.faces.count, closed: closed, smile: smiles.max(),
            known: record.faces.filter { $0.personId != nil }.count,
            blurry: record.isBlurry, groupSize: groupSize, groupRank: groupRank)
    }

    private static func real(_ v: SQLValue?) -> Double? {
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

    /// Feature vectors by image_id for one run, identical to fromRecord for the same photo.
    public static func fromRows(_ db: Database, runId: String) throws -> [Int: [Double]] {
        let photos = try db.query(
            """
            SELECT image_id, quality, sharpness, exposure, aesthetic_score, composition_score,
                   rule_of_thirds, color_balance, color_harmony, crop_risk, is_blurry, similar_cluster
            FROM photo_analysis WHERE run_id = ? AND error IS NULL
            """, [.text(runId)])
        var faces: [Int: [[String: SQLValue]]] = [:]
        for row in try db.query(
            """
            SELECT image_id, left_eye_state, right_eye_state, smile_probability, person_id
            FROM faces WHERE run_id = ?
            """, [.text(runId)])
        {
            if let id = int(row["image_id"]) { faces[id, default: []].append(row) }
        }
        var clusters: [Int: [(Double, Int)]] = [:]
        for row in photos {
            if let c = int(row["similar_cluster"]), let id = int(row["image_id"]) {
                clusters[c, default: []].append((-(real(row["quality"]) ?? 0), id))
            }
        }
        var ranks: [Int: (Int, Int)] = [:]
        for members in clusters.values {
            let sorted = members.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            for (rank, m) in sorted.enumerated() { ranks[m.1] = (sorted.count, rank) }
        }
        var result: [Int: [Double]] = [:]
        for row in photos {
            guard let id = int(row["image_id"]) else { continue }
            let rows = faces[id] ?? []
            let smiles = rows.compactMap { real($0["smile_probability"]) }
            let (size, rank) = ranks[id] ?? (1, 0)
            func text(_ r: [String: SQLValue], _ k: String) -> String? {
                if case .text(let s)? = r[k] { return s }
                return nil
            }
            result[id] = vector(
                quality: real(row["quality"]), sharpness: real(row["sharpness"]), exposure: real(row["exposure"]),
                aesthetic: real(row["aesthetic_score"]), composition: real(row["composition_score"]),
                thirds: real(row["rule_of_thirds"]), balance: real(row["color_balance"]),
                harmony: real(row["color_harmony"]), cropRisk: real(row["crop_risk"]),
                faceCount: rows.count,
                closed: rows.filter { text($0, "left_eye_state") == "closed" || text($0, "right_eye_state") == "closed" }.count,
                smile: smiles.max(), known: rows.filter { int($0["person_id"]) != nil }.count,
                blurry: (int(row["is_blurry"]) ?? 0) != 0, groupSize: size, groupRank: rank)
        }
        return result
    }
}
