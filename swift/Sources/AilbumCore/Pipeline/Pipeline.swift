import Foundation

/// Port of `analyze_library` and its helpers (src/ailbum/pipeline.py).
public enum Pipeline {
    /// Test seam: replaces the active pairwise model lookup.
    nonisolated(unsafe) static var pairwiseOverride: (id: Int, model: LogisticModel)?

    public static func analyzeLibrary(
        source: String, output: String, config: PipelineConfig, recursive: Bool = true,
        progress: ((String) -> Void)? = nil, database: String? = nil
    ) throws -> JSONValue {
        let startedAt = Catalog.utcNow()
        let emit: (String) -> Void = progress ?? { _ in }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: source, isDirectory: &isDir)
        let paths = isDir.boolValue
            ? ImageLoader.discover(root: source, recursive: recursive)
            : (FileManager.default.fileExists(atPath: source) ? [source] : [])
        if paths.isEmpty { throw AilbumError.invalid("No supported images found in \(source)") }
        emit("Этап: Подготовка анализа|Найдено фотографий: \(paths.count)")
        let base = isDir.boolValue ? source : (source as NSString).deletingLastPathComponent
        func display(_ path: String) -> String {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        if config.semanticBatchSize < 1 { throw AilbumError.invalid("Semantic batch size must be positive") }
        if config.geometricNeighborWindow < 1 {
            throw AilbumError.invalid("Geometric neighbor window must be positive")
        }
        if config.geometricTimeWindowMinutes < 1 {
            throw AilbumError.invalid("Geometric time window must be positive")
        }
        if config.storySemanticBreakMinutes < 1 {
            throw AilbumError.invalid("Story semantic break must be at least one minute")
        }

        emit("Этап: Загрузка моделей|Подготавливаем анализ качества, лиц и содержимого")
        let faceBackend = try PhotoAnalysis.faceBackend(config.faceBackend)
        let semanticBackend = try PhotoAnalysis.semanticBackend(config.semanticBackend)
        var semanticError: String?
        let cache = makeCache(config, output: output, database: database,
                              faceBackend: faceBackend, semanticBackend: semanticBackend)
        let faceSimilarity = config.faceSimilarity ?? (faceBackend == "dnn" ? 0.36 : 0.82)

        var records: [PhotoRecord] = []
        var photoFeatures: [PhotoFeatures?] = []
        var faceFeatures: [(photo: Int, face: Int, embedding: [Float])] = []
        var metadataList: [ImageMetadata] = []
        var pending: [(index: Int, preview: RGBImage, sha: String, features: PhotoFeatures)] = []

        func appendFaces(_ index: Int) {
            for (faceIndex, face) in records[index].faces.enumerated() {
                if let embedding = face.embedding { faceFeatures.append((index, faceIndex, embedding)) }
            }
        }
        func flush() {
            if pending.isEmpty { return }
            var semantics: [SemanticRecord?] = Array(repeating: nil, count: pending.count)
            if semanticBackend == "clip" {
                do {
                    let found = try Clip.analyze(
                        pending.map { $0.preview }, threshold: config.semanticThreshold,
                        topK: config.semanticTopK)
                    semantics = found.map { Optional($0) }
                } catch let e {
                    semanticError = "\(type(of: e)): \(StoryNamer.describe(e))"
                    pending.removeAll()
                    return
                }
            }
            for (item, record) in zip(pending, semantics) {
                records[item.index].semantics = record
                cache?.store(sha256: item.sha, record: records[item.index], features: item.features)
            }
            pending.removeAll()
        }

        emit("Этап: Анализ фотографий|Метаданные, качество, лица и содержимое")
        for (offset, path) in paths.enumerated() {
            let index = offset + 1
            emit("[\(index)/\(paths.count)] \(display(path))")
            let metadata = try Metadata.collect(path: path, source: source)
            metadataList.append(metadata)
            let photoId = "photo-" + String(format: "%05d", index)
            let takenAt = metadata.takenAt ?? metadata.modifiedAt
            if let cache, let hit = cache.load(
                sha256: metadata.sha256, photoId: photoId, path: metadata.path, takenAt: takenAt,
                sharpnessThreshold: config.sharpnessThreshold) {
                var cached = hit.0
                cached.path = metadata.path
                records.append(cached)
                photoFeatures.append(hit.1)
                appendFaces(records.count - 1)
                continue
            }
            do {
                var result = try PhotoAnalysis.analyze(
                    path: path, photoId: photoId, takenAt: takenAt, config: config, faceBackend: faceBackend)
                result.record.path = metadata.path
                photoFeatures.append(result.features)
                records.append(result.record)
                appendFaces(records.count - 1)
                pending.append((records.count - 1, result.preview, metadata.sha256, result.features))
                if pending.count >= config.semanticBatchSize { flush() }
            } catch let e {
                records.append(PhotoRecord(
                    photoId: photoId, path: metadata.path, width: 0, height: 0, takenAt: takenAt,
                    sharpness: 0, exposure: 0, quality: 0, isBlurry: true,
                    error: "\(type(of: e)): \(StoryNamer.describe(e))"))
                photoFeatures.append(nil)
            }
        }
        flush()

        emit("Этап: Поиск похожих кадров|Группируем дубли и серии")
        let validIndices = photoFeatures.indices.filter { photoFeatures[$0] != nil }
        let groups = try Similarity.cluster(
            validIndices.map { photoFeatures[$0]! }, hashDistance: config.photoHashDistance,
            histogramThreshold: Float(config.photoHistSimilarity),
            geometricThreshold: config.photoGeometricSimilarity.map { Float($0) },
            captureTimes: validIndices.map { records[$0].takenAt },
            neighborWindow: config.geometricNeighborWindow,
            timeWindowMinutes: config.geometricTimeWindowMinutes)
        var similarGroups: [JSONValue] = []
        let pairwise = try activePairwise(database)
        let selectionModel = pairwise.map { "pairwise:\($0.id)" } ?? "quality"
        for (offset, local) in groups.enumerated() {
            let clusterId = offset + 1
            let members = local.map { validIndices[$0] }
            if members.count > 1 { for i in members { records[i].similarCluster = clusterId } }
            let candidates = members.filter { !records[$0].isBlurry }
            var best: Int?
            if !candidates.isEmpty {
                best = groupWinner(records, members: members, candidates: candidates, model: pairwise?.model)
                records[best!].selected = true
            }
            if members.count > 1 {
                similarGroups.append([
                    "cluster_id": .int(clusterId),
                    "members": .array(members.map { .string(records[$0].photoId) }),
                    "selected": best.map { .string(records[$0].photoId) } ?? .null,
                ])
            }
        }

        emit("Этап: Группировка лиц|Связываем похожие лица с людьми")
        var people: [PersonRecord] = []
        let embeddings = faceFeatures.map { $0.embedding }
        let clusters = Vectors.clusterCosine(embeddings, threshold: Float(faceSimilarity))
        for (offset, members) in clusters.enumerated() {
            let personId = offset + 1
            var faceIds: [String] = []
            var photoIds = Set<String>()
            for featureIndex in members {
                let item = faceFeatures[featureIndex]
                records[item.photo].faces[item.face].personCluster = personId
                faceIds.append(records[item.photo].faces[item.face].faceId)
                photoIds.insert(records[item.photo].photoId)
            }
            var centroid = [Float](repeating: 0, count: embeddings[members[0]].count)
            for m in members { for k in centroid.indices { centroid[k] += embeddings[m][k] } }
            for k in centroid.indices { centroid[k] /= Float(members.count) }
            let norm = centroid.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { for k in centroid.indices { centroid[k] /= norm } }
            people.append(PersonRecord(
                clusterId: personId, faceIds: faceIds, photoIds: photoIds.sorted(),
                embeddingModel: faceBackend == "dnn" ? "sface-2021dec" : "classic-hog-color-v1",
                centroid: centroid))
        }

        emit("Этап: Формирование сюжетов|Объединяем фотографии по времени и содержимому")
        let storyPhotos = zip(records, metadataList).map { record, metadata in
            StoryPhoto(
                photoId: record.photoId, takenAt: record.takenAt,
                gpsLatitude: metadata.gpsLatitude, gpsLongitude: metadata.gpsLongitude,
                people: Set(record.faces.compactMap { $0.personCluster.map { "cluster:\($0)" } }),
                scenes: record.semantics?.scenes ?? [], objects: record.semantics?.objects ?? [],
                embedding: (record.semantics?.embedding).flatMap { $0.isEmpty ? nil : $0 },
                quality: record.quality, isBlurry: record.isBlurry)
        }
        var stories = Stories.detect(
            storyPhotos, gapMinutes: config.storyGapMinutes,
            continuityMinutes: config.storyContinuityMinutes,
            maxDurationHours: config.storyMaxDurationHours)
        emit("Этап: Названия сюжетов|Подбираем названия для групп фотографий")
        let namer = try StoryNamer(
            backend: config.storyNamingBackend, baseURL: config.lmstudioUrl,
            model: config.lmstudioModel, maxImages: config.storyVlmImages,
            timeout: config.storyVlmTimeout)
        stories = try namer.refine(
            stories, photoPaths: Dictionary(records.map { ($0.photoId, $0.path) }, uniquingKeysWith: { $1 }))
        var storyByPhoto: [String: Int] = [:]
        for story in stories { for id in story.photoIds { storyByPhoto[id] = story.storyId } }
        for i in records.indices { records[i].storyId = storyByPhoto[records[i].photoId] }

        let cacheStats: JSONValue = cache?.stats() ?? [
            "enabled": .bool(false), "hits": .int(0), "misses": .int(0), "writes": .int(0),
            "error": .null,
        ]
        let faces = records.flatMap { $0.faces }
        var manifest: JSONValue = [
            "schema_version": .int(6),
            "run_id": .string(Catalog.newRunId()),
            "started_at": .string(startedAt),
            "generated_at": .string(Catalog.utcNow()),
            "source": .string(Catalog.resolve(source)),
            "database": database.map { .string(Catalog.resolve($0)) } ?? .null,
            "face_backend": .string(faceBackend),
            "face_attribute_models": .array(faceBackend == "dnn" ? attributeModels().map { .string($0) } : []),
            "semantic_backend": .string(semanticBackend),
            "semantic_model": semanticBackend == "clip" ? .string(config.clipModel) : .null,
            "semantic_error": semanticError.map { .string($0) } ?? .null,
            "semantic_device": .string(semanticBackend == "clip" ? "coreml" : "cpu"),
            "feature_cache": cacheStats,
            "selection_model": .string(selectionModel),
            "story_naming_backend": .string(namer.backend),
            "story_naming_model": namer.backend == "lmstudio" ? (namer.model.map { .string($0) } ?? .null) : .null,
            "story_naming_error": namer.error.map { .string($0) } ?? .null,
            "config": configJSON(config, faceSimilarity: faceSimilarity),
            "summary": [
                "photos": .int(records.count),
                "errors": .int(records.filter { $0.error != nil }.count),
                "blurry": .int(records.filter { $0.isBlurry }.count),
                "selected": .int(records.filter { $0.selected }.count),
                "similar_groups": .int(similarGroups.count),
                "faces": .int(faces.count),
                "faces_with_eye_state": .int(faces.filter { $0.eyes != nil }.count),
                "faces_with_expression": .int(faces.filter { $0.expression != nil }.count),
                "people_groups": .int(people.count),
                "stories": .int(stories.count),
                "photos_with_aesthetic_score": .int(
                    records.filter { $0.semantics?.aestheticScore != nil }.count),
                "photos_with_scene_tags": .int(
                    records.filter { !($0.semantics?.scenes.isEmpty ?? true) }.count),
                "feature_cache_hits": cacheStats["hits"] ?? .int(0),
            ],
            "similar_groups": .array(similarGroups),
            "people_groups": .array(people.map { $0.toJSON() }),
            "story_groups": .array(stories.map { $0.toJSON() }),
            "photos": .array(records.map { $0.toJSON() }),
        ]
        if let database {
            emit("Этап: Сохранение|Записываем результаты анализа в базу данных")
            let runId = try AnalysisStore.save(
                database: database, source: source, output: output, manifest: manifest,
                records: records, people: people, metadata: metadataList,
                faceSimilarity: faceSimilarity, stories: stories)
            try syncPeople(database: database, runId: runId, records: &records, people: &people)
            if case .object(var o) = manifest {
                o["people_groups"] = .array(people.map { $0.toJSON() })
                o["photos"] = .array(records.map { $0.toJSON() })
                manifest = .object(o)
            }
        }
        emit("Этап: Завершение|Формируем файлы результатов")
        try writeOutputs(output, manifest: manifest, records: records)
        return manifest
    }

    // MARK: helpers

    /// Copies DB-assigned person ids (and public id/name) back into records, as `save_analysis` does in Python.
    static func syncPeople(
        database: String, runId: String, records: inout [PhotoRecord], people: inout [PersonRecord]
    ) throws {
        let db = try Database.open(path: database)
        var byFace: [String: Int] = [:]
        var byCluster: [Int: Int] = [:]
        for row in try db.query(
            "SELECT face_id, person_cluster, person_id FROM faces WHERE run_id = ? AND person_id IS NOT NULL",
            [.text(runId)]) {
            guard case .integer(let pid)? = row["person_id"] else { continue }
            if case .text(let f)? = row["face_id"] { byFace[f] = Int(pid) }
            if case .integer(let c)? = row["person_cluster"] { byCluster[Int(c)] = Int(pid) }
        }
        for i in records.indices {
            for j in records[i].faces.indices {
                records[i].faces[j].personId = byFace[records[i].faces[j].faceId]
            }
        }
        for k in people.indices {
            guard let pid = byCluster[people[k].clusterId] else { continue }
            people[k].personId = pid
            let rows = try db.query("SELECT public_id, name FROM people WHERE id = ?", [.integer(Int64(pid))])
            if case .text(let p)? = rows.first?["public_id"] { people[k].publicId = p }
            if case .text(let n)? = rows.first?["name"] { people[k].name = n }
        }
    }

    static func makeCache(
        _ config: PipelineConfig, output: String, database: String?, faceBackend: String,
        semanticBackend: String
    ) -> FeatureCache? {
        if !config.featureCache { return nil }
        let root = config.featureCacheDir?.path
            ?? (database.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("feature-cache") }
                ?? (output as NSString).appendingPathComponent(".feature-cache"))
        var modelFiles: [JSONValue] = []
        let dir = config.modelsDir.path
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        where name.hasSuffix(".mlpackage") {
            let manifest = (dir as NSString).appendingPathComponent(name + "/Manifest.json")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: manifest) else { continue }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1e9
            modelFiles.append([.string(name), .int(size), .int(Int(mtime))])
        }
        let signature = FeatureCache.signature([
            "max_image_side": .int(config.maxImageSide),
            "geometric_enabled": .bool(config.photoGeometricSimilarity != nil),
            "geometric_max_features": .int(config.geometricMaxFeatures),
            "face_backend": .string(faceBackend),
            "face_models": .array(modelFiles),
            "min_face_size": .int(config.minFaceSize),
            "min_attribute_face_size": .int(config.minAttributeFaceSize),
            "semantic_backend": .string(semanticBackend),
            "semantic_model": .string(config.clipModel),
            "semantic_threshold": .double(config.semanticThreshold),
            "semantic_top_k": .int(config.semanticTopK),
        ])
        return FeatureCache(root: root, signature: signature)
    }

    static func attributeModels() -> [String] {
        var models: [String] = []
        if ModelStore.available("eye") { models.append("open-closed-eye-0001") }
        if ModelStore.available("expression") { models.append("progressive-teacher-mobilefacenet-2022july") }
        return models
    }

    static func activePairwise(_ database: String?) throws -> (id: Int, model: LogisticModel)? {
        if let override = pairwiseOverride { return override }
        guard let database else { return nil }
        return try RankingStore.activeModel(try Database.open(path: database), kind: "pairwise")
    }

    static func groupWinner(
        _ records: [PhotoRecord], members: [Int], candidates: [Int], model: LogisticModel?
    ) -> Int {
        guard let model else {
            var best = candidates[0]
            for c in candidates.dropFirst() where records[c].quality > records[best].quality { best = c }
            return best
        }
        let order = members.sorted {
            records[$0].quality != records[$1].quality ? records[$0].quality > records[$1].quality : $0 < $1
        }
        let vectors = candidates.map {
            RankingFeatures.fromRecord(records[$0], groupSize: members.count, groupRank: order.firstIndex(of: $0)!)
        }
        let scores = model.score(vectors)
        var best = 0
        for k in 1..<max(candidates.count, 1) where k < candidates.count {
            if scores[k] > scores[best]
                || (scores[k] == scores[best] && records[candidates[k]].quality > records[candidates[best]].quality) {
                best = k
            }
        }
        return candidates[best]
    }

    static func configJSON(_ c: PipelineConfig, faceSimilarity: Double) -> JSONValue {
        func opt(_ v: Double?) -> JSONValue { v.map { .double($0) } ?? .null }
        return [
            "sharpness_threshold": .double(c.sharpnessThreshold),
            "photo_hash_distance": .int(c.photoHashDistance),
            "photo_hist_similarity": .double(c.photoHistSimilarity),
            "photo_geometric_similarity": opt(c.photoGeometricSimilarity),
            "geometric_max_features": .int(c.geometricMaxFeatures),
            "geometric_neighbor_window": .int(c.geometricNeighborWindow),
            "geometric_time_window_minutes": .int(c.geometricTimeWindowMinutes),
            "face_similarity": .double(faceSimilarity),
            "min_face_size": .int(c.minFaceSize),
            "min_attribute_face_size": .int(c.minAttributeFaceSize),
            "max_image_side": .int(c.maxImageSide),
            "face_backend": .string(c.faceBackend),
            "semantic_backend": .string(c.semanticBackend),
            "clip_model": .string(c.clipModel),
            "semantic_threshold": .double(c.semanticThreshold),
            "semantic_top_k": .int(c.semanticTopK),
            "semantic_batch_size": .int(c.semanticBatchSize),
            "semantic_device": .string(c.semanticDevice),
            "story_gap_minutes": .int(c.storyGapMinutes),
            "story_continuity_minutes": .int(c.storyContinuityMinutes),
            "story_max_duration_hours": .int(c.storyMaxDurationHours),
            "story_semantic_break_minutes": .int(c.storySemanticBreakMinutes),
            "story_naming_backend": .string(c.storyNamingBackend),
            "lmstudio_url": .string(c.lmstudioUrl),
            "lmstudio_model": .string(c.lmstudioModel),
            "story_vlm_images": .int(c.storyVlmImages),
            "story_vlm_timeout": .double(c.storyVlmTimeout),
            "models_dir": .string(c.modelsDir.path),
            "feature_cache": .bool(c.featureCache),
            "feature_cache_dir": c.featureCacheDir.map { .string($0.path) } ?? .null,
        ]
    }

    // MARK: outputs

    static let csvHeader = [
        "photo_id", "path", "sharpness", "exposure", "quality", "aesthetic_score",
        "composition_score", "rule_of_thirds", "frame_occupancy", "negative_space", "crop_risk",
        "color_balance", "color_harmony", "scene_tags", "object_tags", "blurry", "similar_cluster",
        "story_id", "faces", "selected", "error",
    ]

    static func writeOutputs(_ output: String, manifest: JSONValue, records: [PhotoRecord]) throws {
        let base = URL(fileURLWithPath: output)
        try Data(dump(manifest, 0).utf8).write(to: base.appendingPathComponent("analysis.json"), options: .atomic)
        func num(_ v: Double?) -> String { v.map { "\($0)" } ?? "" }
        func py(_ b: Bool) -> String { b ? "True" : "False" }
        var lines = [csvHeader.joined(separator: ",")]
        for r in records {
            let c = r.composition
            let fields: [String] = [
                r.photoId, r.path, "\(r.sharpness)", "\(r.exposure)", "\(r.quality)",
                num(r.semantics?.aestheticScore), num(c?.score), num(c?.ruleOfThirds),
                num(c?.frameOccupancy), num(c?.negativeSpace), num(c?.cropRisk),
                num(r.color?.balance), num(r.color?.harmony),
                r.semantics.map { $0.scenes.map { $0.label }.joined(separator: ";") } ?? "",
                r.semantics.map { $0.objects.map { $0.label }.joined(separator: ";") } ?? "",
                py(r.isBlurry), r.similarCluster.map { $0 == 0 ? "" : "\($0)" } ?? "",
                r.storyId.map { $0 == 0 ? "" : "\($0)" } ?? "", "\(r.faces.count)", py(r.selected),
                r.error ?? "",
            ]
            lines.append(fields.map(csvQuote).joined(separator: ","))
        }
        try Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
            .write(to: base.appendingPathComponent("selection.csv"), options: .atomic)
    }

    static func csvQuote(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Python `json.dumps(ensure_ascii=False, indent=2)` with sorted keys.
    static func dump(_ value: JSONValue, _ level: Int) -> String {
        let pad = String(repeating: " ", count: (level + 1) * 2)
        let end = String(repeating: " ", count: level * 2)
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
            return "\(d)"
        case .string(let s): return quote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + dump($0, level + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n" + o.keys.sorted().map { pad + quote($0) + ": " + dump(o[$0]!, level + 1) }
                .joined(separator: ",\n") + "\n" + end + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
