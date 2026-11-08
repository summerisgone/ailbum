import Foundation
import Testing
@testable import AilbumCore

private func lbTempDir() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-lb-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func lbInsert(_ db: Database, id: Int, path: String, avail: String = "present") throws {
    try db.execute(
        """
        INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
        file_size_bytes, modified_at, sha256, exif_json, container_metadata_json,
        indexed_at, availability)
        VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024-01-0\(id)', ?, '{}', '{}', 't', ?)
        """,
        [.integer(id), .text(path), .text("\(id).jpg"), .text("\(id).jpg"), .text("sha\(id)"), .text(avail)])
}

@Suite struct LibraryBrowserTests {
    @Test func browserAlbumsFreshDb() throws {
        let dir = try lbTempDir()
        let path = dir + "/a.db"
        let db = try Database.open(path: path)
        _ = try Albums.create(db, title: "Турция 2026", sources: ["/p"], runId: nil, targetCount: 5)
        #expect(try LibraryBrowser.albums(database: path)
                == [AlbumRow(id: 1, title: "Турция 2026", status: "draft", selected: 0, target: 5)])
    }

    @Test func browserPhotosAllAndAlbum() throws {
        let dir = try lbTempDir()
        let path = dir + "/a.db"
        let jpg = dir + "/1.jpg"
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: URL(fileURLWithPath: jpg))
        let db = try Database.open(path: path)
        try lbInsert(db, id: 1, path: jpg)
        try lbInsert(db, id: 2, path: dir + "/gone.jpg")
        let aid = try Albums.create(db, title: "T", sources: ["/p"], runId: nil, targetCount: 3)
        try db.execute("INSERT INTO album_photos (album_id, image_id, position, added_at) VALUES (?, 1, 1, 't')", [.integer(aid)])

        let all = try LibraryBrowser.photos(database: path, albumId: nil)
        #expect(all == [PhotoTile(imageId: 1, path: jpg, selected: true),
                        PhotoTile(imageId: 2, path: nil, selected: false)])
        let inAlbum = try LibraryBrowser.photos(database: path, albumId: aid)
        #expect(inAlbum == [PhotoTile(imageId: 1, path: jpg, selected: true)])
        #expect(try LibraryBrowser.albums(database: path).first?.selected == 1)
    }

    @Test func browserCreatesMissingDatabase() throws {
        let path = try lbTempDir() + "/new.sqlite3"
        #expect(try LibraryBrowser.albums(database: path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
