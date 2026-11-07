import Foundation

extension Database {
    public static let schemaVersion = 12

    public static func open(path: String) throws -> Database {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        let db = try Database(path: path)
        try db.executeScript("PRAGMA foreign_keys = ON")
        _ = try db.query("PRAGMA journal_mode = WAL", [])
        let version = try db.userVersion()
        if (1...(schemaVersion - 1)).contains(version) { throw AilbumError.schemaTooOld(version) }
        if version == 0 {
            guard let url = Bundle.module.url(forResource: "schema", withExtension: "sql"),
                  let sql = try? String(contentsOf: url, encoding: .utf8)
            else { throw AilbumError.sqlite("schema.sql resource missing") }
            try db.executeScript(sql)
            try db.executeScript("PRAGMA user_version = \(schemaVersion)")
        }
        return db
    }
}
