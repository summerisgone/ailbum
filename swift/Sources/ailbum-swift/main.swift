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
guard args.count == 2, args[0] == "quality" || args[0] == "db-stats" else {
    FileHandle.standardError.write(Data("usage: ailbum-swift quality <image> | db-stats <db>\n".utf8))
    exit(64)
}

do {
    if args[0] == "quality" {
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
