import Foundation
import SQLite3
import Testing
@testable import AilbumCore

private func tmpPath(_ name: String = "a.sqlite3") -> String {
    let dir = NSTemporaryDirectory() + "ailbum-\(UUID().uuidString)"
    return dir + "/" + name
}

@Test func testRejectsOldSchema() throws {
    let path = tmpPath()
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var h: OpaquePointer?
    #expect(sqlite3_open(path, &h) == SQLITE_OK)
    sqlite3_exec(h, "CREATE TABLE images(id, missing); PRAGMA user_version = 11;", nil, nil, nil)
    sqlite3_close(h)
    #expect(throws: AilbumError.schemaTooOld(11)) { try Database.open(path: path) }
}

@Test func testTransactionRollback() throws {
    let db = try Database.open(path: tmpPath())
    try db.execute("CREATE TABLE t(x INTEGER)", [])
    struct Boom: Error {}
    #expect(throws: Boom.self) {
        try db.transaction {
            try db.execute("INSERT INTO t VALUES (1)", [])
            throw Boom()
        }
    }
    #expect(try db.query("SELECT COUNT(*) AS n FROM t", []) == [["n": .integer(0)]])
}

@Test func testTransactionCommit() throws {
    let db = try Database.open(path: tmpPath())
    try db.execute("CREATE TABLE t(x INTEGER)", [])
    try db.transaction { try db.execute("INSERT INTO t VALUES (?)", [.integer(5)]) }
    #expect(try db.query("SELECT x FROM t", []) == [["x": .integer(5)]])
}

@Test func testUnicodePath() throws {
    let path = tmpPath("x").replacingOccurrences(of: "/x", with: "/Фото альбом/a.sqlite3")
    let db = try Database.open(path: path)
    #expect(try db.userVersion() == 12)
}

@Test func testBlobRoundTrip() throws {
    let db = try Database.open(path: tmpPath())
    try db.execute("CREATE TABLE b(d BLOB, s TEXT, r REAL, n INTEGER)", [])
    try db.execute("INSERT INTO b VALUES (?,?,?,?)",
                   [.blob(Data([0, 255, 1])), .text("привет"), .real(1.5), .null])
    let rows = try db.query("SELECT * FROM b", [])
    #expect(rows == [["d": .blob(Data([0, 255, 1])), "s": .text("привет"), "r": .real(1.5), "n": .null]])
}

@Test func testFreshSchema() throws {
    let db = try Database.open(path: tmpPath())
    #expect(try db.userVersion() == 12)
    let names = try db.query("SELECT name FROM sqlite_master WHERE type='table'", [])
        .compactMap { row -> String? in if case .text(let s) = row["name"] { return s } else { return nil } }
    for t in ["albums", "images", "faces", "people", "layouts", "selection_events", "ranking_models"] {
        #expect(names.contains(t))
    }
    #expect(try db.query("SELECT COUNT(*) AS n FROM images", []) == [["n": .integer(0)]])
}

@Test func testForeignKeysOn() throws {
    let db = try Database.open(path: tmpPath())
    #expect(try db.query("PRAGMA foreign_keys", []) == [["foreign_keys": .integer(1)]])
}

@Test func testWAL() throws {
    let db = try Database.open(path: tmpPath())
    #expect(try db.query("PRAGMA journal_mode", []) == [["journal_mode": .text("wal")]])
}

@Test func testOpenV12Twice() throws {
    let path = tmpPath()
    let db = try Database.open(path: path)
    try db.execute("INSERT INTO people(public_id, name, embedding_model, centroid_embedding, embedding_dim, created_at, updated_at) VALUES ('p1', ?, 'm', x'00', 1, 't', 't')", [.text("a")])
    let db2 = try Database.open(path: path)
    #expect(try db2.query("SELECT COUNT(*) AS n FROM people", []) == [["n": .integer(1)]])
}

@Test func testNestedTransactionInnerRollback() throws {
    let db = try Database.open(path: tmpPath())
    try db.execute("CREATE TABLE t(x INTEGER)", [])
    struct Boom: Error {}
    try db.transaction {
        try db.execute("INSERT INTO t VALUES (1)", [])
        try? db.transaction {
            try db.execute("INSERT INTO t VALUES (2)", [])
            throw Boom()
        }
        try db.transaction { try db.execute("INSERT INTO t VALUES (3)", []) }
    }
    #expect(try db.query("SELECT x FROM t ORDER BY x", []) == [["x": .integer(1)], ["x": .integer(3)]])
    try db.transaction { try db.execute("INSERT INTO t VALUES (4)", []) }
    #expect(try db.query("SELECT COUNT(*) AS n FROM t", []) == [["n": .integer(3)]])
}
