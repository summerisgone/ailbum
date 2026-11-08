import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AilbumCore

private func storeTempDir() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func storePopulate(album: Bool = true) throws -> String {
    let path = try storeTempDir() + "/a.db"
    let db = try Database.open(path: path)
    try db.execute("INSERT INTO analysis_runs VALUES ('r1','/p','/o','t','t','none','{}','{}','completed')", [])
    for i in 1...2 {
        try db.execute(
            """
            INSERT INTO images (id, path, source_root, relative_path, file_name, extension,
            file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)
            VALUES (?, ?, '/p', ?, ?, '.jpg', 1, '2024', ?, '{}', '{}', 't')
            """,
            [.integer(i), .text("/p/\(i).jpg"), .text("\(i).jpg"), .text("\(i).jpg"), .text("sha\(i)")])
        try db.execute(
            """
            INSERT INTO photo_analysis (run_id, image_id, photo_id, sharpness, exposure,
            quality, is_blurry, story_id, selected) VALUES ('r1', ?, ?, 0.5, 0.5, 0.5, 0, 1, 0)
            """, [.integer(i), .text("p\(i)")])
    }
    if album { _ = try Albums.create(db, title: "T", sources: ["/p"], runId: "r1", targetCount: 2) }
    return path
}

private func scratchScript(_ body: String) throws -> URL {
    let url = URL(fileURLWithPath: try storeTempDir() + "/job.sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "ailbum.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

/// Real DesktopBridge by default; `SUPERLITE_REAL=1` also selects real code. The fake is only used by
/// tests that need canned bridge answers (archive), where a real archive would build proxies from photos.
@MainActor private func makeStore(_ db: String?, script: String = "sleep 30", defaults: UserDefaults? = nil) throws -> AppStore {
    AppStore(database: db, jobRunner: JobRunner(executable: try scratchScript(script)), defaults: defaults ?? isolatedDefaults())
}

@MainActor private func eventually(_ cond: () -> Bool) async {
    for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 25_000_000) }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, JSONValue)] = []
    func add(_ a: String, _ p: JSONValue) { lock.lock(); items.append((a, p)); lock.unlock() }
    var actions: [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.0) }
    func payload(_ action: String) -> JSONValue? { lock.lock(); defer { lock.unlock() }; return items.last { $0.0 == action }?.1 }
}

@Suite(.serialized) @MainActor struct AppStoreSuite {
    @Test func bootstrapLoadsLibraryAndAlbums() async throws {
        let db = try storePopulate()
        let store = try makeStore(db)
        await store.bootstrap()
        #expect(store.library?.photos.count == 2)
        #expect(store.library?.album?.id == 1)
        #expect(store.albums.count == 1)
        #expect(store.error == nil)
    }

    @Test func bootstrapCreatesMissingDatabaseAndResetsMedia() async throws {
        let path = try storeTempDir() + "/new.db"
        let store = try makeStore(path)
        await store.bootstrap()
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(store.library?.photos.isEmpty == true)
        #expect(store.mediaPaths.isEmpty)
    }

    @Test func bootstrapWithoutDatabaseSetsError() async throws {
        let store = try makeStore(nil)
        await store.bootstrap()
        #expect(store.error != nil)
    }

    @Test func favoriteToggleUpdatesLibraryAndClearsPending() async throws {
        let db = try storePopulate()
        let store = try makeStore(db)
        await store.bootstrap()
        let before = store.library!.selected_count
        let beforeFav = store.library!.photos.first { $0.id == 1 }!.favorite
        await store.setFavorite(imageId: 1, favorite: !beforeFav)
        #expect(store.pending.isEmpty)
        #expect(store.error == nil)
        let photo = store.library!.photos.first { $0.id == 1 }!
        #expect(photo.favorite == !beforeFav)
        #expect(store.library!.selected_count == before + (beforeFav ? -1 : 1))
        let fresh = try AppModels.decode(Library.self, DesktopBridge.dispatch(database: db, action: "library.bootstrap", payload: [:]))
        #expect(fresh.photos.first { $0.id == 1 }!.favorite == !beforeFav)
    }

    @Test func favoriteFailureRollsBack() async throws {
        let db = try storePopulate()
        let store = try makeStore(db)
        await store.bootstrap()
        let before = store.library
        AppStore.bridge = { _, action, _ in
            if action == "favorite.set" { throw AilbumError.invalid("boom") }
            return .null
        }
        defer { AppStore.resetSeams() }
        await store.setFavorite(imageId: 1, favorite: true)
        #expect(store.library == before)
        #expect(store.error != nil)
        #expect(store.pending.isEmpty)
    }

    @Test func renameAndDeleteAlbum() async throws {
        let db = try storePopulate()
        let store = try makeStore(db)
        await store.bootstrap()
        await store.renameAlbum(1, title: "Турция")
        #expect(store.albums.first?.title == "Турция")
        #expect(store.library?.album?.title == "Турция")
        await store.deleteAlbum(1, forgetDecisions: false)
        #expect(store.albums.isEmpty)
        #expect(store.library?.album == nil)
        #expect(store.error == nil)
    }

    @Test func setTargetClampsAndPersists() async throws {
        let db = try storePopulate()
        let store = try makeStore(db)
        await store.bootstrap()
        await store.setTarget(5000)
        #expect(store.library?.target_count == 999)
        let fresh = try AppModels.decode(Library.self, DesktopBridge.dispatch(database: db, action: "library.bootstrap", payload: [:]))
        #expect(fresh.target_count == 999)
    }

    @Test func archiveFlowUsesTrashSeam() async throws {
        let log = CallLog()
        AppStore.bridge = { _, action, payload in
            log.add(action, payload)
            switch action {
            case "album.prepare_archive":
                return log.actions.filter { $0 == "album.prepare_archive" }.count == 1
                    ? ["needs_export": true, "trash": [], "blocked": []]
                    : ["needs_export": false, "trash": ["/x/a.jpg", "/x/b.jpg"],
                       "blocked": [["image_id": 7, "reason": "r"]]]
            case "album.complete_archive": return ["archived": 1]
            case "library.bootstrap":
                return ["database": "d", "album": .null, "albums": [], "run": .null, "target_count": 1,
                        "selected_count": 0, "stories": [], "photos": []]
            case "album.list": return []
            case "album.usage":
                return ["database_bytes": 0, "proxies_bytes": 0, "feature_cache_bytes": 0,
                        "images": ["present": 0, "missing": 0, "archived": 0]]
            default: return [:]
            }
        }
        var trashed: [String] = []
        AppStore.trashItem = { url in
            if url.path == "/x/b.jpg" { throw AilbumError.invalid("nope") }
            trashed.append(url.path)
        }
        defer { AppStore.resetSeams() }
        let store = try makeStore("/tmp/never-opened.db")
        let result = await store.archiveAlbum(3) { URL(fileURLWithPath: "/export") }
        #expect(result == .archived(archived: 1, blocked: [BlockedImage(image_id: 7, reason: "r")], failed: ["/x/b.jpg"]))
        #expect(trashed == ["/x/a.jpg"])
        #expect(store.archiveNote == result)
        #expect(log.actions.prefix(4) == ["album.prepare_archive", "layout.export", "album.prepare_archive", "album.complete_archive"])
        #expect(log.payload("layout.export")?["folder"]?.stringValue == "/export")
        #expect(log.payload("album.complete_archive")?["trashed"] == ["/x/a.jpg"])
        #expect(store.albumBusy == false)
    }

    @Test func archiveCancelledWhenNoFolder() async throws {
        let log = CallLog()
        AppStore.bridge = { _, action, payload in
            log.add(action, payload)
            return action == "album.prepare_archive" ? ["needs_export": true, "trash": [], "blocked": []] : [:]
        }
        AppStore.trashItem = { _ in Issue.record("trash must not be called") }
        defer { AppStore.resetSeams() }
        let store = try makeStore("/tmp/never-opened.db")
        let result = await store.archiveAlbum(3) { nil }
        #expect(result == .cancelled)
        #expect(store.archiveNote == nil)
        #expect(log.actions.prefix(1) == ["album.prepare_archive"])
        #expect(!log.actions.contains("layout.export") && !log.actions.contains("album.complete_archive"))
    }

    @Test func archiveNeedsExportAfterExport() async throws {
        AppStore.bridge = { _, action, _ in
            action == "album.prepare_archive"
                ? ["needs_export": true, "trash": [], "blocked": [["image_id": 2, "reason": "x"]]] : [:]
        }
        defer { AppStore.resetSeams() }
        let store = try makeStore("/tmp/never-opened.db")
        let result = await store.archiveAlbum(3) { URL(fileURLWithPath: "/export") }
        #expect(result == .needsExport(blocked: [BlockedImage(image_id: 2, reason: "x")]))
    }

    @Test func databaseChangeRefusedWhileJobRuns() async throws {
        let db = try storePopulate()
        let other = try storeTempDir() + "/other.db"
        let store = try makeStore(db)
        await store.startDatabaseJob(kind: "index", sources: [])
        #expect(store.error == nil)
        await store.openDatabase(path: other)
        #expect(store.error == "Дождитесь завершения текущей операции")
        #expect(store.database == db)
        store.error = nil
        await store.createDatabase(path: other)
        #expect(store.error == "Дождитесь завершения текущей операции")
        #expect(!FileManager.default.fileExists(atPath: other))
        store.error = nil
        await store.startDatabaseJob(kind: "analyze", sources: [])
        #expect(store.error == "Уже выполняется добавление или анализ фотографий")
        await store.cancelDatabaseJob()
        #expect(store.job.status == .cancelled)
        #expect(store.job.stage == "Операция отменена")
    }

    @Test func unknownJobKindRejected() async throws {
        let store = try makeStore(try storePopulate())
        await store.startDatabaseJob(kind: "bogus", sources: [])
        #expect(store.error == "Неизвестный тип операции")
    }

    @Test func completedJobReloadsLibrary() async throws {
        let db = try storePopulate()
        let store = try makeStore(db, script: "echo '{\"type\":\"complete\",\"result\":{}}'")
        await store.startDatabaseJob(kind: "index", sources: [])
        await eventually { store.library != nil }
        #expect(store.job.status == .complete)
        #expect(store.library?.photos.count == 2)
    }

    @Test func openAndCreateDatabasePersistLastPath() async throws {
        let db = try storePopulate()
        let defaults = isolatedDefaults()
        let store = try makeStore(nil, defaults: defaults)
        await store.openDatabase(path: db)
        #expect(store.database == db)
        #expect(defaults.string(forKey: "ailbum.database") == db)
        #expect(store.library?.photos.count == 2)
        let fresh = try storeTempDir() + "/c.db"
        await store.createDatabase(path: fresh)
        #expect(defaults.string(forKey: "ailbum.database") == fresh)
        #expect(store.library?.photos.isEmpty == true)
        let again = try makeStore(nil, defaults: defaults)
        #expect(again.database == fresh)
    }

    @Test func thumbnailsFromImageIOAndCache() async throws {
        let dir = try storeTempDir()
        let file = dir + "/big.png"
        try writePNG(file, width: 1600, height: 1200)
        let db = try storePopulate()
        let store = try makeStore(db)
        store.mediaPaths[1] = file
        let thumb = await store.thumbnail(imageId: 1)
        #expect(thumb != nil)
        #expect(max(thumb!.width, thumb!.height) == 720)
        #expect(await store.thumbnail(imageId: 99) == nil)
        #expect(AppStore.thumbnailCacheLimit == 300)
        let original = await store.original(imageId: 1)
        #expect(original?.width == 1600)
    }

    @Test func faceThumbnailDecodesBase64() async throws {
        let dir = try storeTempDir()
        let file = dir + "/f.png"
        try writePNG(file, width: 40, height: 30)
        let b64 = try Data(contentsOf: URL(fileURLWithPath: file)).base64EncodedString()
        AppStore.bridge = { _, action, _ in
            action == "face.thumbnail" ? ["mime_type": "image/jpeg", "base64": .string(b64)] : .null
        }
        defer { AppStore.resetSeams() }
        let store = try makeStore("/tmp/never-opened.db")
        let img = await store.faceThumbnail(faceId: 5)
        #expect(img?.width == 40)
    }

    @Test func peopleAndLayoutPayloads() async throws {
        let log = CallLog()
        AppStore.bridge = { _, action, payload in
            log.add(action, payload)
            return [:]
        }
        defer { AppStore.resetSeams() }
        let store = try makeStore("/tmp/never-opened.db")
        await store.mergePerson(source: 1, target: 2)
        #expect(log.payload("person.merge") == ["source_id": 1, "target_id": 2])
        await store.assignFace(4, personId: nil)
        #expect(log.payload("face.assign") == ["face_id": 4, "person_id": .null])
        _ = try? await store.layoutSwapCells(spreadId: 1, cellA: 0, cellB: 1)
        #expect(log.payload("layout.swap_cells") == ["spread_id": 1, "cell_a": 0, "cell_b": 1])
        _ = try? await store.layoutRecompose(spreadId: 1, prompt: nil)
        #expect(log.payload("layout.recompose_spread") == ["spread_id": 1, "prompt": ""])
        let p = AppLayoutParams(orientation: .vertical, spread_count: 4, min_photos: 1, max_photos: 3)
        _ = try? await store.layoutPreflight(albumId: 9, params: p)
        #expect(log.payload("layout.preflight")?["album_id"] == 9)
        #expect(log.payload("layout.preflight")?["spread_count"] == 4)
    }
}

private func writePNG(_ path: String, width: Int, height: Int) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
