import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private let packageDir: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.path
}()

private func run(_ args: [String]) throws -> (code: Int32, out: String, err: String) {
    let bin = Process()
    bin.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    bin.arguments = ["swift", "build", "--package-path", packageDir, "--show-bin-path"]
    let binPipe = Pipe()
    bin.standardOutput = binPipe
    bin.standardError = Pipe()
    try bin.run()
    let binData = binPipe.fileHandleForReading.readDataToEndOfFile()
    bin.waitUntilExit()
    let dir = String(decoding: binData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: dir + "/ailbum-swift")
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    try p.run()
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
}

private func writePNG(_ path: String) throws {
    let w = 32, h = 24
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        rgba[i] = UInt8(x * 8); rgba[i + 1] = UInt8(y * 10); rgba[i + 2] = UInt8((x * y) % 256)
    } }
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = rgba.withUnsafeMutableBytes {
        CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func tmpDir() throws -> String {
    let d = NSTemporaryDirectory() + "ailbum-cli-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

@Test func testQualityJSON() throws {
    let png = try tmpDir() + "/p.png"
    try writePNG(png)
    let r = try run(["quality", png])
    #expect(r.code == 0)
    let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [String: Any]
    #expect(Set(obj.keys) == ["path", "width", "height", "sharpness", "exposure", "quality", "phash"])
    #expect(obj["width"] as? Int == 32)
    #expect(obj["height"] as? Int == 24)
    let ph = obj["phash"] as! String
    #expect(ph.count == 16)
    #expect(ph.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(r.out.filter { $0 == "\n" }.count == 1)
}

@Test func testMissingFile() throws {
    let r = try run(["quality", "/nonexistent/x.png"])
    #expect(r.code == 2)
    #expect(r.err.hasPrefix("ошибка:"))
}

@Test func testDbStats() throws {
    let db = try tmpDir() + "/new.sqlite3"
    let r = try run(["db-stats", db])
    #expect(r.code == 0)
    #expect(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "{\"images\":0,\"people\":0,\"albums\":0}")
}

@Test func testUsage() throws {
    let r = try run([])
    #expect(r.code == 64)
    #expect(r.err.contains("usage"))
}
