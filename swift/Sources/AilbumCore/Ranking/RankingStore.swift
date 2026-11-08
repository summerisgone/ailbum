import Foundation

public enum RankingStore {
    static let featureVersion = RankingFeatures.version

    public static func saveModel(_ db: Database, kind: String, model: LogisticModel, metrics: JSONValue,
                                 active: Bool) throws -> Int {
        if active {
            try db.execute("UPDATE ranking_models SET active = 0 WHERE kind = ?", [.text(kind)])
        }
        let data = try JSONSerialization.data(withJSONObject: model.toJSON(), options: [.sortedKeys, .withoutEscapingSlashes])
        try db.execute(
            """
            INSERT INTO ranking_models (kind, feature_version, model_json, metrics_json, active, trained_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(kind), .integer(model.featureVersion), .text(String(decoding: data, as: UTF8.self)),
             .text(AnalysisStore.json(metrics)), .integer(active ? 1 : 0), .text(Catalog.utcNow())])
        let rows = try db.query("SELECT last_insert_rowid() AS id", [])
        guard case .integer(let id)? = rows.first?["id"] else { return 0 }
        return Int(id)
    }

    public static func activeRow(_ db: Database, kind: String) throws -> [String: SQLValue]? {
        let rows = try db.query(
            """
            SELECT id, feature_version, model_json, metrics_json FROM ranking_models
            WHERE kind = ? AND active = 1 ORDER BY id DESC LIMIT 1
            """, [.text(kind)])
        guard let row = rows.first, row["feature_version"] == .integer(featureVersion) else { return nil }
        return row
    }

    public static func activeModel(_ db: Database, kind: String) throws -> (id: Int, model: LogisticModel)? {
        guard let row = try activeRow(db, kind: kind),
              case .integer(let id)? = row["id"], case .text(let text)? = row["model_json"] else { return nil }
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AilbumError.decode("model json")
        }
        return (Int(id), try LogisticModel.fromJSON(obj))
    }
}
