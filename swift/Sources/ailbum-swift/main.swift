import AilbumCore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("ошибка: " + message + "\n").utf8))
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
let compareOK = args.count == 3 && args[0] == "compare"
guard compareOK || (args.count == 2 && (args[0] == "quality" || args[0] == "db-stats")) else {
    FileHandle.standardError.write(Data("usage: ailbum-swift quality <image> | db-stats <db> | compare <image> <image>\n".utf8))
    exit(64)
}

do {
    if args[0] == "compare" {
        for path in args[1...2] where !FileManager.default.fileExists(atPath: path) {
            fail("файл не найден: \(path)", code: 2)
        }
        let a = try SIFT.extract(try ImageLoader.load(path: args[1]))
        let b = try SIFT.extract(try ImageLoader.load(path: args[2]))
        let s = try Similarity.geometric(a, b)
        func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        printJSON([
            "score": r4(s.score), "mutual_matches": s.mutualMatches, "inliers": s.inliers,
            "inlier_ratio": r4(s.inlierRatio), "coverage_left": r4(s.coverageLeft),
            "coverage_right": r4(s.coverageRight),
        ])
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
