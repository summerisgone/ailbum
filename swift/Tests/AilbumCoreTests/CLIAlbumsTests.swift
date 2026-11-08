import Foundation
import Testing
@testable import AilbumCore

private final class Lines: @unchecked Sendable {
    var items: [String] = []
    var text: String { items.joined(separator: "\n") }
}

private func makeCLIDB() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/db.sqlite3"
    let db = try Database.open(path: path)
    _ = try Albums.create(db, title: "Турция 2026", sources: ["/p"], runId: nil, targetCount: 5)
    return path
}

@discardableResult
private func cli(_ args: [String], _ db: String, _ lines: Lines, input: String? = nil) throws -> Int32? {
    try CLIAlbums.run(args + ["--database", db], out: { lines.items.append($0) }, input: { input })
}

private func albumStatus(_ db: String) throws -> String {
    try Albums.get(try Database.open(path: db), 1)["status"]?.stringValue ?? ""
}

private func resetSeams() {
    CLIAlbums.prepareOverride = nil
    CLIAlbums.trashOverride = nil
    CLIAlbums.completeOverride = nil
    CLIAlbums.planForgetOverride = nil
    CLIAlbums.forgetOverride = nil
    CLIAlbums.usageOverride = nil
}

@Suite(.serialized) struct CLIAlbumsTests {
    @Test func listShowOrderReopen() throws {
        let db = try makeCLIDB()
        var l = Lines()
        try cli(["album", "list"], db, l)
        #expect(l.text.contains("1\tdraft\tТурция 2026\t0/5"))
        try cli(["album", "order", "1"], db, Lines())
        #expect(try albumStatus(db) == "ordered")
        l = Lines()
        try cli(["album", "show", "1"], db, l)
        #expect(l.text.contains("Турция 2026"))
        try cli(["album", "reopen", "1"], db, Lines())
        #expect(try albumStatus(db) == "draft")
        l = Lines()
        try cli(["album", "list", "--json"], db, l)
        #expect(l.text.contains("\"Турция 2026\""))
    }

    @Test func deleteAndErrorExit() throws {
        let db = try makeCLIDB()
        var l = Lines()
        try cli(["album", "delete", "1"], db, l)
        #expect(l.text.contains("удалён"))
        l = Lines()
        do {
            try cli(["album", "show", "1"], db, l)
            Issue.record("expected throw")
        } catch AilbumError.invalid(let msg) {
            #expect(msg.contains("Альбом не найден"))
        }
    }

    @Test func archiveNeedsExportExits1() throws {
        defer { resetSeams() }
        let db = try makeCLIDB()
        CLIAlbums.prepareOverride = { _, a in
            ["album_id": .int(a), "needs_export": true, "trash": [],
             "blocked": [["image_id": 5, "reason": "входит в черновик «Лето»"]]]
        }
        let l = Lines()
        let code = try cli(["album", "archive", "1"], db, l)
        #expect(code == 1)
        #expect(l.text.contains("Нужен экспорт") && l.text.contains("входит в черновик «Лето»"))
    }

    @Test func archiveConfirmation() throws {
        defer { resetSeams() }
        let db = try makeCLIDB()
        let trashed = Lines()
        CLIAlbums.prepareOverride = { _, a in
            ["album_id": .int(a), "needs_export": false, "trash": ["/p/ф ото.jpg"], "blocked": []]
        }
        CLIAlbums.trashOverride = { trashed.items.append(contentsOf: $0); return $0 }
        CLIAlbums.completeOverride = { _, _, t in ["archived": .int(t.count), "status": "archived", "cache_removed": 0] }
        var l = Lines()
        try cli(["album", "archive", "1"], db, l, input: "n")
        #expect(l.items.contains("Перенести 1 файлов в Корзину? [y/N] "))
        #expect(l.text.contains("Отменено") && trashed.items.isEmpty)
        l = Lines()
        try cli(["album", "archive", "1", "--yes"], db, l)
        #expect(trashed.items == ["/p/ф ото.jpg"])
        #expect(l.text.contains("\"archived\": 1"))
        l = Lines()
        try cli(["album", "archive", "1"], db, l, input: "да")
        #expect(trashed.items.count == 2)
    }

    @Test func archiveEofCancels() throws {
        defer { resetSeams() }
        let db = try makeCLIDB()
        CLIAlbums.prepareOverride = { _, a in
            ["album_id": .int(a), "needs_export": false, "trash": ["/p/a.jpg"], "blocked": []]
        }
        let l = Lines()
        try cli(["album", "archive", "1"], db, l, input: nil)
        #expect(l.text.contains("Отменено"))
    }

    @Test func forgetRequiresYes() throws {
        defer { resetSeams() }
        let db = try makeCLIDB()
        let done = Lines()
        CLIAlbums.planForgetOverride = { _, a, _ in ["album_id": .int(a ?? 0), "images": 3] }
        CLIAlbums.forgetOverride = { _, a, _ in done.items.append(String(a ?? 0)); return ["forgotten": 3] }
        var l = Lines()
        try cli(["forget", "--album", "1"], db, l)
        #expect(done.items.isEmpty && l.text.contains("\"images\": 3"))
        #expect(l.text.contains("Это только план"))
        l = Lines()
        try cli(["forget", "--album", "1", "--yes"], db, l)
        #expect(done.items == ["1"])
    }

    @Test func usageInMb() throws {
        defer { resetSeams() }
        let db = try makeCLIDB()
        CLIAlbums.usageOverride = { _ in
            ["database_bytes": .int(2 * 1024 * 1024), "proxies_bytes": 0, "feature_cache_bytes": 0,
             "images": ["present": 2, "missing": 0, "archived": 1]]
        }
        let l = Lines()
        let code = try CLIAlbums.run(["db", "usage", "--database", db], out: { l.items.append($0) }, input: { nil })
        #expect(code == 0)
        #expect(l.text.contains("2.0 МБ") && l.text.contains("в архиве 1"))
    }

    @Test func rankingStatus() throws {
        let db = try makeCLIDB()
        let l = Lines()
        try cli(["ranking", "status"], db, l)
        #expect(l.text.contains("нужно не меньше 50 пар из 2 альбомов"))
    }

    @Test func notAlbumCommand() throws {
        let l = Lines()
        #expect(try CLIAlbums.run(["index", "x"], out: { l.items.append($0) }, input: { nil }) == nil)
        #expect(try CLIAlbums.run(["db", "stats"], out: { l.items.append($0) }, input: { nil }) == nil)
    }
}
