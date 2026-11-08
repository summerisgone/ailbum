import AilbumCore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("Ошибка: " + message + "\n").utf8))
    exit(code)
}

func printJSON(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}

func hex(_ bits: [Bool]) -> String {
    var s = ""
    for i in stride(from: 0, to: bits.count, by: 4) {
        var v = 0
        for j in i..<min(i + 4, bits.count) { v = (v << 1) | (bits[j] ? 1 : 0) }
        s += String(v, radix: 16)
    }
    return s
}

func count(_ db: Database, _ table: String) throws -> Int {
    guard case .integer(let n)? = try db.query("SELECT COUNT(*) AS n FROM \(table)", []).first?["n"] else { return 0 }
    return Int(n)
}

let args = Array(CommandLine.arguments.dropFirst())

let eventEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}()

if args.first == "job" {
    let code = DesktopJob.run(Array(args.dropFirst())) { event in
        if let data = try? eventEncoder.encode(event) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }
    exit(code)
}

do {
    if let code = try CLIAlbums.run(args, out: { print($0); fflush(stdout) }, input: { readLine() }) { exit(code) }
    if let code = try CLICatalog.run(args, out: { print($0); fflush(stdout) }) { exit(code) }
} catch {
    if case AilbumError.invalid(let message) = error { fail(message, code: 2) }
    fail("\(error)", code: 2)
}

guard (args.count == 2 && args[0] == "analyze-image") || (args.count == 2 && (args[0] == "quality" || args[0] == "db-stats")) else {
    FileHandle.standardError.write(Data("usage: ailbum-swift job <kind> ... | album|forget|ranking|db|analyze|index|people|models|compare|evaluate ... | quality <image> | db-stats <db> | analyze-image <image>\n".utf8))
    exit(64)
}

do {
    if args[0] == "analyze-image" {
        let path = args[1]
        guard FileManager.default.fileExists(atPath: path) else { fail("файл не найден: \(path)", code: 2) }
        let image = try ImageLoader.load(path: path)
        func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        func tags(_ t: [TagRecord]) -> [[String: Any]] { t.map { ["label": $0.label, "confidence": $0.confidence] } }
        // a missing model gives an empty value for that key
        let faces: [[String: Any]] = ((try? FaceAnalyzer.analyze(image, minFaceSize: 40, minAttributeFaceSize: 64)) ?? []).map { f in
            var d: [String: Any] = [
                "bbox": [f.detection.bbox.x, f.detection.bbox.y, f.detection.bbox.w, f.detection.bbox.h],
                "confidence": r4(Double(f.detection.confidence)),
            ]
            if let e = f.attributes.expression { d["expression"] = e }
            if let p = f.attributes.leftEyeOpenProbability { d["left_eye_open_probability"] = p }
            if let p = f.attributes.rightEyeOpenProbability { d["right_eye_open_probability"] = p }
            return d
        }
        let objects: [[String: Any]] = ((try? YOLOX.detect(image)) ?? []).map {
            ["label": $0.label, "score": r4(Double($0.score)), "bbox": [$0.bbox.x, $0.bbox.y, $0.bbox.z, $0.bbox.w].map { r4(Double($0)) }]
        }
        var semantic: [String: Any] = [:]
        if let s = try? Clip.analyze([image], threshold: 0.15, topK: 3).first {
            semantic = ["scenes": tags(s.scenes), "objects": tags(s.objects)]
            if let a = s.aestheticScore { semantic["aesthetic_score"] = a }
            if let m = s.model { semantic["model"] = m }
        }
        printJSON(["faces": faces, "objects": objects, "semantic": semantic])
    } else if args[0] == "quality" {
        let path = args[1]
        guard FileManager.default.fileExists(atPath: path) else { fail("файл не найден: \(path)", code: 2) }
        let image = try ImageLoader.load(path: path)
        let sharpness = try Quality.sharpness(image, maxSide: 1600)
        let exposure = Quality.exposure(image, maxSide: 800)
        let feats = HashColor.features(image)
        printJSON([
            "path": path, "width": image.width, "height": image.height,
            "sharpness": sharpness, "exposure": exposure,
            "quality": Quality.score(sharpness: sharpness, exposure: exposure),
            "phash": hex(feats.phash),
        ])
    } else {
        let db = try Database.open(path: args[1])
        // fixed key order required by the contract, so no JSONSerialization here
        print("{\"images\":\(try count(db, "images")),\"people\":\(try count(db, "people")),\"albums\":\(try count(db, "albums"))}")
    }
} catch {
    fail("\(error)", code: 2)
}
