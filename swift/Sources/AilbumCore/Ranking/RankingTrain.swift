import Foundation

public enum RankingTrain {
    static let minPairs = 50
    static let minAlbums = 2
    static let minPointwiseEvents = 5
    static let reason = "нужно не меньше \(minPairs) пар из \(minAlbums) альбомов"
    static let pointwiseReason = "нужно не меньше \(minAlbums) альбомов с \(minPointwiseEvents) ручными действиями"
    static let quality = RankingFeatures.names.firstIndex(of: "quality")!

    struct AlbumData {
        var albumId: Int
        var vectors: [Int: [Double]]
        var final: Set<Int>
        var pairs: [(Int, Int)]
        var explicitEvents: Int
        var shas: Set<String>
        var touched: [[Int]]
    }

    private static func int(_ v: SQLValue?) -> Int? {
        if case .integer(let i)? = v { return Int(i) }
        return nil
    }

    private static func load(_ db: Database) throws -> [AlbumData] {
        var result: [AlbumData] = []
        let albums = try db.query("SELECT id, run_id FROM albums WHERE run_id IS NOT NULL ORDER BY id", [])
        for row in albums {
            guard let albumId = int(row["id"]), case .text(let runId)? = row["run_id"] else { continue }
            let vectors = try RankingFeatures.fromRows(db, runId: runId)
            if vectors.isEmpty { continue }
            var final = Set<Int>()
            for r in try db.query("SELECT image_id FROM album_photos WHERE album_id = ?", [.integer(albumId)]) {
                if let i = int(r["image_id"]), vectors[i] != nil { final.insert(i) }
            }
            var events: [JSONValue] = []
            for r in try db.query(
                "SELECT image_id, source, action FROM selection_events WHERE album_id = ? ORDER BY id",
                [.integer(albumId)]) {
                events.append(.object(["image_id": JSONValue(r["image_id"] ?? .null),
                                       "source": JSONValue(r["source"] ?? .null),
                                       "action": JSONValue(r["action"] ?? .null)]))
            }
            var groups: [Int: [Int]] = [:]
            for r in try db.query(
                "SELECT image_id, similar_cluster FROM photo_analysis"
                + " WHERE run_id = ? AND error IS NULL AND similar_cluster IS NOT NULL ORDER BY image_id",
                [.text(runId)]) {
                if let i = int(r["image_id"]), let c = int(r["similar_cluster"]) { groups[c, default: []].append(i) }
            }
            var shas = Set<String>()
            for r in try db.query(
                "SELECT sha256 FROM images WHERE id IN (SELECT image_id FROM photo_analysis WHERE run_id = ?)",
                [.text(runId)]) {
                if case .text(let s)? = r["sha256"] { shas.insert(s) }
            }
            var touched: [[Int]] = []
            for cluster in groups.keys.sorted() {
                let members = groups[cluster]!
                if !RankingLabels.groupPairs(events: events, final: final, groups: [cluster: members]).isEmpty {
                    touched.append(members)
                }
            }
            let explicitCount = events.filter {
                if case .string(let s)? = $0["source"] { return RankingLabels.explicit.contains(s) }
                return false
            }.count
            result.append(AlbumData(
                albumId: albumId, vectors: vectors, final: final,
                pairs: RankingLabels.groupPairs(events: events, final: final, groups: groups),
                explicitEvents: explicitCount, shas: shas, touched: touched))
        }
        return result
    }

    /// Albums sharing any sha256 stay together so duplicates never straddle train and test.
    static func components(_ albums: [AlbumData]) -> [[AlbumData]] {
        var parent = Array(0..<albums.count)
        func find(_ start: Int) -> Int {
            var i = start
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var owner: [String: Int] = [:]
        for (i, album) in albums.enumerated() {
            for sha in album.shas {
                let j = owner[sha] ?? { owner[sha] = i; return i }()
                parent[find(i)] = find(j)
            }
        }
        var order: [Int] = []
        var buckets: [Int: [AlbumData]] = [:]
        for (i, album) in albums.enumerated() {
            let root = find(i)
            if buckets[root] == nil { order.append(root) }
            buckets[root, default: []].append(album)
        }
        return order.map { buckets[$0]! }
    }

    private static func fit(_ x: [[Double]], _ y: [Double]) -> LogisticModel {
        var model = LogisticModel.fit(x: x, y: y, l2: 1.0)
        model.featureVersion = RankingFeatures.version
        model.featureNames = RankingFeatures.names
        return model
    }

    private static func pairwiseXY(_ albums: [AlbumData]) -> ([[Double]], [Double]) {
        var rows: [[Double]] = [], labels: [Double] = []
        for album in albums {
            for (w, l) in album.pairs {
                let diff = zip(album.vectors[w]!, album.vectors[l]!).map { $0 - $1 }
                rows.append(diff)
                rows.append(diff.map { -$0 })
                labels += [1.0, 0.0]
            }
        }
        return (rows, labels)
    }

    private static func argmax(_ s: [Double]) -> Int {
        var best = 0
        for i in s.indices where s[i] > s[best] { best = i }
        return best
    }

    /// Top-1 hits and group count over touched groups (model nil means max quality).
    private static func pairwiseHits(_ model: LogisticModel?, _ albums: [AlbumData]) -> (Int, Int) {
        var hits = 0, total = 0
        for album in albums {
            for members in album.touched {
                let order = members.sorted()
                let vecs = order.map { album.vectors[$0]! }
                let scores = model.map { $0.score(vecs) } ?? vecs.map { $0[quality] }
                if album.final.contains(order[argmax(scores)]) { hits += 1 }
                total += 1
            }
        }
        return (hits, total)
    }

    private static func trainPairwise(_ albums: [AlbumData]) -> (LogisticModel?, [String: JSONValue], String?) {
        let usable = albums.filter { !$0.pairs.isEmpty }
        let pairs = usable.reduce(0) { $0 + $1.pairs.count }
        if pairs < minPairs || usable.count < minAlbums { return (nil, [:], reason) }
        let folds = components(usable)
        var metrics: [String: JSONValue] = [
            "pairs": .int(pairs), "albums": .int(usable.count), "accuracy": .null, "baseline": .null]
        if folds.count >= 2 {
            var hits = 0, baseHits = 0, total = 0
            for (i, fold) in folds.enumerated() {
                let rest = folds.enumerated().filter { $0.offset != i }.flatMap { $0.element }
                let (x, y) = pairwiseXY(rest)
                if y.isEmpty { continue }
                let model = fit(x, y)
                let (h, t) = pairwiseHits(model, fold)
                hits += h
                total += t
                baseHits += pairwiseHits(nil, fold).0
            }
            if total > 0 {
                metrics["accuracy"] = .double(Double(hits) / Double(total))
                metrics["baseline"] = .double(Double(baseHits) / Double(total))
                metrics["groups"] = .int(total)
            }
        }
        let (x, y) = pairwiseXY(usable)
        return (fit(x, y), metrics, nil)
    }

    private static func pointwiseXY(_ albums: [AlbumData]) -> ([[Double]], [Double]) {
        var rows: [[Double]] = [], labels: [Double] = []
        for album in albums {
            for id in album.vectors.keys.sorted() {
                rows.append(album.vectors[id]!)
                labels.append(album.final.contains(id) ? 1.0 : 0.0)
            }
        }
        return (rows, labels)
    }

    private static func precision(_ model: LogisticModel?, _ albums: [AlbumData]) -> [Double] {
        var result: [Double] = []
        for album in albums {
            let ids = album.vectors.keys.sorted()
            let k = album.final.count
            if k == 0 { continue }
            let vecs = ids.map { album.vectors[$0]! }
            let scores = model.map { $0.score(vecs) } ?? vecs.map { $0[quality] }
            let top = scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
                .prefix(k).map { ids[$0] }
            result.append(Double(Set(top).intersection(album.final).count) / Double(k))
        }
        return result
    }

    private static func trainPointwise(_ albums: [AlbumData]) -> (LogisticModel?, [String: JSONValue], String?) {
        let usable = albums.filter { $0.explicitEvents >= minPointwiseEvents && !$0.final.isEmpty }
        if usable.count < minAlbums { return (nil, [:], pointwiseReason) }
        let folds = components(usable)
        var metrics: [String: JSONValue] = ["albums": .int(usable.count), "precision": .null, "baseline": .null]
        if folds.count >= 2 {
            var got: [Double] = [], base: [Double] = []
            for (i, fold) in folds.enumerated() {
                let rest = folds.enumerated().filter { $0.offset != i }.flatMap { $0.element }
                let (x, y) = pointwiseXY(rest)
                let model = fit(x, y)
                got += precision(model, fold)
                base += precision(nil, fold)
            }
            if !got.isEmpty {
                metrics["precision"] = .double(got.reduce(0, +) / Double(got.count))
                metrics["baseline"] = .double(base.reduce(0, +) / Double(base.count))
            }
        }
        let (x, y) = pointwiseXY(usable)
        return (fit(x, y), metrics, nil)
    }

    private static func better(_ metrics: [String: JSONValue], _ key: String) -> Bool {
        guard let a = metrics[key]?.doubleValue, let b = metrics["baseline"]?.doubleValue else { return false }
        return a >= b
    }

    private static func run(_ db: Database, save: Bool) throws -> JSONValue {
        let albums = try load(db)
        var out: [String: JSONValue] = ["pairwise": .null, "pointwise": .null, "reason": .null]
        var reasons: [String] = []
        for kind in ["pairwise", "pointwise"] {
            let key = kind == "pairwise" ? "accuracy" : "precision"
            let (model, info0, why) = kind == "pairwise" ? trainPairwise(albums) : trainPointwise(albums)
            guard let model else {
                reasons.append(why ?? "")
                continue
            }
            var info = info0
            let active = better(info, key)
            info["active"] = .bool(active)
            if save {
                info["id"] = .int(try RankingStore.saveModel(db, kind: kind, model: model, metrics: .object(info), active: active))
            }
            out[kind] = .object(info)
        }
        if case .null = out["pairwise"]!, case .null = out["pointwise"]! {
            out["reason"] = .string(reasons[0])
        }
        return .object(out)
    }

    public static func train(_ db: Database) throws -> JSONValue { try run(db, save: true) }

    public static func evaluate(_ db: Database) throws -> JSONValue { try run(db, save: false) }

    public static func status(_ db: Database) throws -> JSONValue {
        let albums = try load(db)
        let pairs = albums.reduce(0) { $0 + $1.pairs.count }
        let contributing = albums.filter { !$0.pairs.isEmpty }.count
        var result: [String: JSONValue] = ["pairs": .int(pairs), "albums": .int(contributing)]
        for kind in ["pairwise", "pointwise"] {
            guard let row = try RankingStore.activeRow(db, kind: kind), let id = int(row["id"]),
                  case .text(let text)? = row["metrics_json"] else {
                result[kind] = .null
                continue
            }
            var obj: [String: JSONValue] = ["id": .int(id)]
            if case .object(let m) = try JSONValue.parse(text) { obj.merge(m) { _, new in new } }
            result[kind] = .object(obj)
        }
        let enough = pairs >= minPairs && contributing >= minAlbums
        result["reason"] = enough ? .null : .string(reason)
        return .object(result)
    }
}
