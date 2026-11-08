import CryptoKit
import Foundation

/// Versioned, non-critical cache of complete per-photo CV results (Swift `.swcache` format).
public final class FeatureCache {
    public static let schemaVersion = 1

    public let directory: String
    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var writes = 0
    public private(set) var error: String?
    private let lock = NSLock()

    public var available: Bool { error == nil }

    public static func signature(_ settings: JSONValue) -> String {
        var merged = settings.objectValue ?? [:]
        merged["schema"] = .int(schemaVersion)
        let payload = Data(PyJSON.encode(.object(merged)).utf8)
        let hex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(20))
    }

    public init(root: String, signature: String) {
        directory = (root as NSString).appendingPathComponent(signature)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            self.error = Self.describe(error)
        }
    }

    public func load(sha256: String, photoId: String, path: String, takenAt: String?,
                     sharpnessThreshold: Double) -> (PhotoRecord, PhotoFeatures)? {
        lock.lock()
        defer { lock.unlock() }
        if !available { return nil }
        let file = (directory as NSString).appendingPathComponent("\(sha256).swcache")
        guard let data = FileManager.default.contents(atPath: file),
              let parsed = Self.decode(data, photoId: photoId, path: path, takenAt: takenAt,
                                       sharpnessThreshold: sharpnessThreshold)
        else {
            misses += 1
            return nil
        }
        hits += 1
        return parsed
    }

    public func store(sha256: String, record: PhotoRecord, features: PhotoFeatures) {
        lock.lock()
        defer { lock.unlock() }
        if !available { return }
        let final = (directory as NSString).appendingPathComponent("\(sha256).swcache")
        let temporary = (directory as NSString).appendingPathComponent("\(sha256).tmp")
        do {
            try Self.encode(record: record, features: features).write(to: URL(fileURLWithPath: temporary))
            if rename(temporary, final) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
            writes += 1
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            self.error = Self.describe(error)
        }
    }

    public func stats() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        return [
            "enabled": .bool(available),
            "directory": .string(directory),
            "hits": .int(hits),
            "misses": .int(misses),
            "writes": .int(writes),
            "error": error.map { .string($0) } ?? .null,
        ]
    }

    private static func describe(_ error: Error) -> String {
        "\(type(of: error)): \(error.localizedDescription)"
    }

    // MARK: encoding

    private static func encode(record: PhotoRecord, features: PhotoFeatures) -> Data {
        let geometric = features.geometric
        var meta: [String: JSONValue] = [
            "width": .int(record.width),
            "height": .int(record.height),
            "sharpness": .double(record.sharpness),
            "exposure": .double(record.exposure),
            "quality": .double(record.quality),
            "composition": record.composition.map(compositionJSON) ?? .null,
            "color": record.color.map {
                ["balance": .double($0.balance), "harmony": .double($0.harmony),
                 "mean_saturation": .double($0.meanSaturation)]
            } ?? .null,
            "semantics": record.semantics.map(semanticsJSON) ?? .null,
            "faces": .array(record.faces.map(faceJSON)),
        ]
        meta["geometric"] = geometric.map {
            ["width": .int($0.width), "height": .int($0.height), "has_descriptors": .bool(true)]
        } ?? .null
        meta["shapes"] = [
            "phash": .int(features.phash.count),
            "histogram": .int(features.histogram.count),
            "keypoints": .int(geometric?.keypoints.count ?? 0),
            "descriptors": .int(geometric?.descriptors.count ?? 0),
        ]
        let json = Data(PyJSON.encode(.object(meta)).utf8)
        var out = Data()
        var length = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(json)
        out.append(contentsOf: features.phash.map { $0 ? UInt8(1) : 0 })
        appendFloats(&out, features.histogram)
        if let geometric {
            appendFloats(&out, geometric.keypoints.flatMap { [$0.x, $0.y] })
            appendFloats(&out, geometric.descriptors)
        }
        return out
    }

    private static func appendFloats(_ out: inout Data, _ values: [Float]) {
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        }
    }

    private static func num(_ v: Double?) -> JSONValue { v.map { .double($0) } ?? .null }
    private static func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }
    private static func int(_ v: Int?) -> JSONValue { v.map { .int($0) } ?? .null }

    private static func compositionJSON(_ c: CompositionRecord) -> JSONValue {
        [
            "rule_of_thirds": .double(c.ruleOfThirds),
            "frame_occupancy": .double(c.frameOccupancy),
            "negative_space": .double(c.negativeSpace),
            "crop_risk": .double(c.cropRisk),
            "score": .double(c.score),
            "main_subject": c.mainSubject.map {
                ["bbox": .array([$0.bbox.x, $0.bbox.y, $0.bbox.z, $0.bbox.w].map { .double($0) }),
                 "center": .array([$0.center.x, $0.center.y].map { .double($0) }),
                 "source": .string($0.source)]
            } ?? .null,
        ]
    }

    private static func tagsJSON(_ tags: [TagRecord]) -> JSONValue {
        .array(tags.map { ["label": .string($0.label), "confidence": .double($0.confidence)] })
    }

    private static func floatsJSON(_ values: [Float]?) -> JSONValue {
        values.map { .array($0.map { .double(Double($0)) }) } ?? .null
    }

    private static func semanticsJSON(_ s: SemanticRecord) -> JSONValue {
        [
            "aesthetic_score": num(s.aestheticScore),
            "model": str(s.model),
            "scenes": tagsJSON(s.scenes),
            "objects": tagsJSON(s.objects),
            "embedding": floatsJSON(s.embedding),
        ]
    }

    private static func faceJSON(_ f: FaceRecord) -> JSONValue {
        [
            "face_id": .string(f.faceId),
            "bbox": .array([f.bbox.x, f.bbox.y, f.bbox.z, f.bbox.w].map { .int($0) }),
            "confidence": .double(f.confidence),
            "person_cluster": int(f.personCluster),
            "person_id": int(f.personId),
            "database_id": int(f.databaseId),
            "embedding": floatsJSON(f.embedding),
            "eyes": f.eyes.map {
                ["left": str($0.left), "right": str($0.right),
                 "left_open_probability": num($0.leftOpenProbability),
                 "right_open_probability": num($0.rightOpenProbability),
                 "both_open": $0.bothOpen.map { .bool($0) } ?? .null]
            } ?? .null,
            "expression": f.expression.map {
                ["label": .string($0.label), "confidence": .double($0.confidence),
                 "smile_probability": .double($0.smileProbability),
                 "scores": .object($0.scores.mapValues { .double($0) })]
            } ?? .null,
        ]
    }

    // MARK: decoding

    private static func decode(_ data: Data, photoId: String, path: String, takenAt: String?,
                               sharpnessThreshold: Double) -> (PhotoRecord, PhotoFeatures)? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let jsonLength = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard jsonLength <= bytes.count - 4,
              let text = String(data: Data(bytes[4..<(4 + jsonLength)]), encoding: .utf8),
              let meta = try? JSONValue.parse(text), meta.objectValue != nil,
              let shapes = meta["shapes"],
              let phashCount = shapes["phash"]?.intValue, let histCount = shapes["histogram"]?.intValue,
              let keyCount = shapes["keypoints"]?.intValue, let descCount = shapes["descriptors"]?.intValue,
              phashCount >= 0, histCount >= 0, keyCount >= 0, descCount >= 0,
              phashCount < 1 << 24, histCount < 1 << 24, keyCount < 1 << 24, descCount < 1 << 28
        else { return nil }
        let floatCount = histCount + keyCount * 2 + descCount
        guard bytes.count - 4 - jsonLength == phashCount + floatCount * 4 else { return nil }
        var offset = 4 + jsonLength
        let phash = bytes[offset..<(offset + phashCount)].map { $0 != 0 }
        offset += phashCount
        func floats(_ n: Int) -> [Float] {
            defer { offset += n * 4 }
            return (0..<n).map { i in
                let p = offset + i * 4
                return Float(bitPattern: UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8
                    | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24)
            }
        }
        let histogram = floats(histCount)
        var geometric: GeometricFeatures?
        let keypoints = floats(keyCount * 2)
        let descriptors = floats(descCount)
        if let g = meta["geometric"], g.objectValue != nil {
            guard let w = g["width"]?.intValue, let h = g["height"]?.intValue else { return nil }
            geometric = GeometricFeatures(
                keypoints: (0..<keyCount).map { SIMD2(keypoints[$0 * 2], keypoints[$0 * 2 + 1]) },
                descriptors: descriptors, width: w, height: h)
        }
        guard let record = loadRecord(meta, photoId: photoId, path: path, takenAt: takenAt,
                                      sharpnessThreshold: sharpnessThreshold)
        else { return nil }
        return (record, PhotoFeatures(phash: phash, histogram: histogram, geometric: geometric))
    }

    private static func loadRecord(_ m: JSONValue, photoId: String, path: String, takenAt: String?,
                                   sharpnessThreshold: Double) -> PhotoRecord? {
        guard let width = m["width"]?.intValue, let height = m["height"]?.intValue,
              let sharpness = m["sharpness"]?.doubleValue, let exposure = m["exposure"]?.doubleValue,
              let quality = m["quality"]?.doubleValue, let faceItems = m["faces"]?.arrayValue
        else { return nil }
        var composition: CompositionRecord?
        if let c = m["composition"], c.objectValue != nil {
            guard let loaded = loadComposition(c) else { return nil }
            composition = loaded
        }
        var color: ColorRecord?
        if let c = m["color"], c.objectValue != nil {
            guard let b = c["balance"]?.doubleValue, let h = c["harmony"]?.doubleValue,
                  let s = c["mean_saturation"]?.doubleValue else { return nil }
            color = ColorRecord(balance: b, harmony: h, meanSaturation: s)
        }
        var semantics: SemanticRecord?
        if let s = m["semantics"], s.objectValue != nil {
            guard let loaded = loadSemantics(s) else { return nil }
            semantics = loaded
        }
        var faces: [FaceRecord] = []
        for (index, item) in faceItems.enumerated() {
            guard let face = loadFace(item, photoId: photoId, index: index + 1) else { return nil }
            faces.append(face)
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return PhotoRecord(photoId: photoId, path: resolved, width: width, height: height, takenAt: takenAt,
                           sharpness: sharpness, exposure: exposure, quality: quality,
                           isBlurry: sharpness < sharpnessThreshold, composition: composition,
                           color: color, semantics: semantics, faces: faces)
    }

    private static func doubles(_ v: JSONValue?, count: Int) -> [Double]? {
        guard let items = v?.arrayValue, items.count == count else { return nil }
        let out = items.compactMap { $0.doubleValue }
        return out.count == count ? out : nil
    }

    private static func loadComposition(_ c: JSONValue) -> CompositionRecord? {
        guard let r = c["rule_of_thirds"]?.doubleValue, let f = c["frame_occupancy"]?.doubleValue,
              let n = c["negative_space"]?.doubleValue, let k = c["crop_risk"]?.doubleValue,
              let s = c["score"]?.doubleValue else { return nil }
        var subject: SubjectRecord?
        if let sub = c["main_subject"], sub.objectValue != nil {
            guard let b = doubles(sub["bbox"], count: 4), let ce = doubles(sub["center"], count: 2),
                  let source = sub["source"]?.stringValue else { return nil }
            subject = SubjectRecord(bbox: SIMD4(b[0], b[1], b[2], b[3]), center: SIMD2(ce[0], ce[1]), source: source)
        }
        return CompositionRecord(ruleOfThirds: r, frameOccupancy: f, negativeSpace: n, cropRisk: k,
                                 score: s, mainSubject: subject)
    }

    private static func loadTags(_ v: JSONValue?) -> [TagRecord]? {
        guard let items = v?.arrayValue else { return [] }
        var out: [TagRecord] = []
        for item in items {
            guard let l = item["label"]?.stringValue, let c = item["confidence"]?.doubleValue else { return nil }
            out.append(TagRecord(label: l, confidence: c))
        }
        return out
    }

    private static func loadFloats(_ v: JSONValue?) -> [Float]?? {
        guard let v, v != .null else { return .some(nil) }
        guard let items = v.arrayValue else { return nil }
        let out = items.compactMap { $0.doubleValue.map { Float($0) } }
        return out.count == items.count ? .some(out) : nil
    }

    private static func loadSemantics(_ s: JSONValue) -> SemanticRecord? {
        guard let scenes = loadTags(s["scenes"]), let objects = loadTags(s["objects"]),
              let embedding = loadFloats(s["embedding"]) else { return nil }
        return SemanticRecord(aestheticScore: s["aesthetic_score"]?.doubleValue, model: s["model"]?.stringValue,
                              scenes: scenes, objects: objects, embedding: embedding)
    }

    private static func loadFace(_ d: JSONValue, photoId: String, index: Int) -> FaceRecord? {
        guard let box = d["bbox"]?.arrayValue, box.count == 4,
              let b = Optional(box.compactMap { $0.intValue }), b.count == 4,
              let confidence = d["confidence"]?.doubleValue,
              let embedding = loadFloats(d["embedding"]) else { return nil }
        var eyes: EyeStateRecord?
        if let e = d["eyes"], e.objectValue != nil {
            eyes = EyeStateRecord(left: e["left"]?.stringValue, right: e["right"]?.stringValue,
                                  leftOpenProbability: e["left_open_probability"]?.doubleValue,
                                  rightOpenProbability: e["right_open_probability"]?.doubleValue,
                                  bothOpen: e["both_open"]?.boolValue)
        }
        var expression: ExpressionRecord?
        if let e = d["expression"], e.objectValue != nil {
            guard let label = e["label"]?.stringValue, let c = e["confidence"]?.doubleValue,
                  let smile = e["smile_probability"]?.doubleValue,
                  let scores = e["scores"]?.objectValue else { return nil }
            expression = ExpressionRecord(label: label, confidence: c, smileProbability: smile,
                                          scores: scores.compactMapValues { $0.doubleValue })
        }
        return FaceRecord(faceId: "\(photoId)-face-\(String(format: "%02d", index))",
                          bbox: SIMD4(b[0], b[1], b[2], b[3]), confidence: confidence,
                          embedding: embedding, eyes: eyes, expression: expression)
    }
}

/// Python `json.dumps(ensure_ascii=True, sort_keys=True, separators=(",", ":"))`.
private enum PyJSON {
    static func encode(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v):
            if v.isNaN { return "NaN" }
            if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
            return v.description
        case .string(let v): return string(v)
        case .array(let v): return "[" + v.map(encode).joined(separator: ",") + "]"
        case .object(let v):
            return "{" + v.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
                .map { string($0) + ":" + encode(v[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }
}
