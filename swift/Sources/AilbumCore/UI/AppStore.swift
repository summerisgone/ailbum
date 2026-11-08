import CoreGraphics
import Foundation
import ImageIO
import Observation

/// State and actions of the app. Each action mirrors one `window.ailbum.*` entry of
/// desktop/electron/preload.cjs, its handler in main.cjs and the reload behaviour of desktop/src/App.tsx.
/// Actions that feed the UI state (library, albums, people) record failures in `error`;
/// layout, face and summary queries throw so the calling view can show its own message.
@MainActor @Observable
public final class AppStore {
    public static let thumbnailCacheLimit = 300
    public static let defaultsKey = "ailbum.database"
    static let busyMessage = "Дождитесь завершения текущей операции"

    // Test seams.
    nonisolated(unsafe) static var bridge: @Sendable (String, String, JSONValue) throws -> JSONValue = {
        try DesktopBridge.dispatch(database: $0, action: $1, payload: $2)
    }
    nonisolated(unsafe) static var trashItem: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
    static func resetSeams() {
        bridge = { try DesktopBridge.dispatch(database: $0, action: $1, payload: $2) }
        trashItem = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    public private(set) var database: String?
    public private(set) var library: Library?
    public private(set) var albums: [Album] = []
    public private(set) var usage: Usage?
    public private(set) var people: PeopleLibrary?
    public var error: String?
    public private(set) var job = JobState()
    public private(set) var pending: Set<Int> = []
    public private(set) var archiveNote: ArchiveResult?
    public private(set) var albumBusy = false
    public private(set) var autofilling = false

    var mediaPaths: [Int: String] = [:]
    @ObservationIgnored private let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = AppStore.thumbnailCacheLimit
        return c
    }()
    @ObservationIgnored private let jobRunner: JobRunner
    @ObservationIgnored private let defaults: UserDefaults

    public var albumId: Int? { library?.album?.id }
    public var readOnly: Bool { library?.album.map { $0.status != .draft } ?? false }

    public init(database: String?, jobRunner: JobRunner, defaults: UserDefaults = .standard) {
        self.jobRunner = jobRunner
        self.defaults = defaults
        self.database = database ?? defaults.string(forKey: AppStore.defaultsKey)
    }

    // MARK: Plumbing

    static func message(_ error: Error) -> String {
        switch error {
        case AilbumError.invalid(let s), AilbumError.sqlite(let s), AilbumError.decode(let s), AilbumError.metal(let s): return s
        default: return error.localizedDescription
        }
    }

    /// Runs the bridge call on a background thread, never on the main actor.
    private func call(_ action: String, _ payload: JSONValue = [:]) async throws -> JSONValue {
        guard let database else { throw AilbumError.invalid("База данных не выбрана") }
        let bridge = AppStore.bridge
        let result = try await Task.detached { try bridge(database, action, payload) }.value
        // The database was switched while the call ran: the answer belongs to the old one.
        guard self.database == database else { throw StaleDatabase() }
        return result
    }

    private func call<T: Decodable>(_ type: T.Type, _ action: String, _ payload: JSONValue = [:]) async throws -> T {
        try AppModels.decode(type, try await call(action, payload))
    }

    private struct StaleDatabase: Error {}

    private func guarded(_ body: () async throws -> Void) async {
        do { try await body() } catch is StaleDatabase {} catch { self.error = AppStore.message(error) }
    }

    private func applyLibrary(_ next: Library) {
        library = next
        albums = next.albums
        error = nil
    }

    private func remember(_ path: String) {
        database = path
        defaults.set(path, forKey: AppStore.defaultsKey)
    }

    // MARK: Library

    /// main.cjs bootstrap(): creates a missing database, resets the media maps, then applyLibrary.
    public func bootstrap(albumId: Int? = nil) async {
        await guarded { try await loadLibrary(albumId: albumId) }
    }

    private func loadLibrary(albumId: Int?) async throws {
        guard let database else { throw AilbumError.invalid("База данных не выбрана") }
        if !FileManager.default.fileExists(atPath: database) { _ = try await call("database.initialize") }
        let next = try await call(Library.self, "library.bootstrap", albumId.map { ["album_id": .int($0)] } ?? [:])
        mediaPaths = Dictionary(next.photos.compactMap { p in p.media_path.map { (p.id, $0) } }, uniquingKeysWith: { $1 })
        cache.removeAllObjects()
        applyLibrary(next)
    }

    /// App.tsx reload(): bootstrap, then refresh albums and usage.
    public func reload(albumId: Int? = nil) async {
        await guarded {
            try await loadLibrary(albumId: albumId)
            try await refreshAlbums()
        }
    }

    private func refreshAlbums() async throws {
        albums = try await call([Album].self, "album.list")
        usage = try await call(Usage.self, "album.usage")
    }

    public func openDatabase(path: String) async {
        guard !jobRunner.isRunning else { error = AppStore.busyMessage; return }
        remember(URL(fileURLWithPath: path).path)
        await bootstrap()
    }

    public func createDatabase(path: String) async {
        guard !jobRunner.isRunning else { error = AppStore.busyMessage; return }
        remember(URL(fileURLWithPath: path).path)
        await guarded {
            _ = try await call("database.initialize")
            try await loadLibrary(albumId: nil)
        }
    }

    public func getDatabaseSummary() async throws -> DatabaseSummary {
        try await call(DatabaseSummary.self, "database.summary")
    }

    /// App.tsx toggleFavorite: optimistic update, rollback and error on failure.
    public func setFavorite(imageId: Int, favorite: Bool) async {
        guard let current = library else { return }
        guard let photo = current.photos.first(where: { $0.id == imageId }) else {
            error = "Фото \(imageId) не найдено в каталоге"; return
        }
        guard let album = current.album, !readOnly, !pending.contains(imageId) else { return }
        let maxPosition = current.photos.map { $0.selection_position ?? 0 }.max() ?? 0
        pending.insert(photo.id)
        var next = current
        next.selected_count += favorite ? 1 : -1
        next.photos = current.photos.map {
            guard $0.id == imageId else { return $0 }
            var p = $0
            p.favorite = favorite
            p.selection_position = favorite ? maxPosition + 1 : nil
            return p
        }
        library = next
        do {
            let result = try await call(FavoriteResult.self, "favorite.set",
                ["album_id": .int(album.id), "image_id": .int(imageId), "favorite": .bool(favorite)])
            library?.selected_count = result.selected_count
        } catch is StaleDatabase {
        } catch {
            library = current
            self.error = AppStore.message(error)
        }
        pending.remove(imageId)
    }

    /// App.tsx saveTarget: clamp to 1...999, update locally, persist.
    public func setTarget(_ count: Int) async {
        guard let album = library?.album, !readOnly else { return }
        let clamped = min(999, max(1, count))
        library?.target_count = clamped
        await guarded { _ = try await call("target.set", ["album_id": .int(album.id), "target_count": .int(clamped)]) }
    }

    public func autofill() async {
        guard let id = albumId else { return }
        autofilling = true
        await guarded {
            _ = try await call("selection.autofill", ["album_id": .int(id)])
            try await loadLibrary(albumId: id)
        }
        autofilling = false
    }

    // MARK: Albums

    public func listAlbums() async {
        await guarded { try await refreshAlbums() }
    }

    public func getUsage() async {
        await guarded { usage = try await call(Usage.self, "album.usage") }
    }

    private func albumAction(reopen: Bool = true, _ body: () async throws -> Void) async {
        albumBusy = true
        await guarded {
            try await body()
            if reopen { try await loadLibrary(albumId: albumId); try await refreshAlbums() }
            else { try await refreshAlbums() }
        }
        albumBusy = false
    }

    /// App.tsx onOpen: reload(id).
    public func openAlbum(_ id: Int) async { await reload(albumId: id) }

    public func setAlbumStatus(_ id: Int, status: AlbumStatus) async {
        await albumAction {
            _ = try await call("album.status", ["album_id": .int(id), "status": .string(status.rawValue)])
        }
    }

    public func renameAlbum(_ id: Int, title: String) async {
        await albumAction { _ = try await call("album.rename", ["album_id": .int(id), "title": .string(title)]) }
    }

    public func deleteAlbum(_ id: Int, forgetDecisions: Bool) async {
        let active = albumId
        await albumAction(reopen: false) {
            _ = try await call("album.delete", ["album_id": .int(id), "forget_decisions": .bool(forgetDecisions)])
            if id == active { try await loadLibrary(albumId: nil) }
        }
    }

    public func confirmMissing(imageId: Int) async {
        await guarded {
            _ = try await call("album.confirm_missing", ["image_ids": [.int(imageId)]])
            await reload(albumId: albumId)
        }
    }

    /// main.cjs album:archive, then App.tsx archiveAlbum (note + reload). `.cancelled` when no folder is chosen.
    @discardableResult
    public func archiveAlbum(_ id: Int, chooseFolder: () async -> URL?) async -> ArchiveResult? {
        albumBusy = true
        archiveNote = nil
        var outcome: ArchiveResult?
        do {
            outcome = try await runArchive(id, chooseFolder: chooseFolder)
            if outcome != .cancelled { archiveNote = outcome }
            try await loadLibrary(albumId: albumId)
            try await refreshAlbums()
        } catch is StaleDatabase {
        } catch { self.error = AppStore.message(error) }
        albumBusy = false
        return outcome
    }

    private func runArchive(_ id: Int, chooseFolder: () async -> URL?) async throws -> ArchiveResult {
        let idPayload: JSONValue = ["album_id": .int(id)]
        var plan = try await call("album.prepare_archive", idPayload)
        func blocked() -> [BlockedImage] { (try? AppModels.decode([BlockedImage].self, plan["blocked"] ?? [])) ?? [] }
        if plan["needs_export"]?.boolValue == true {
            guard let folder = await chooseFolder() else { return .cancelled }
            _ = try await call("layout.export", ["album_id": .int(id), "folder": .string(folder.standardizedFileURL.path)])
            plan = try await call("album.prepare_archive", idPayload)
            if plan["needs_export"]?.boolValue == true { return .needsExport(blocked: blocked()) }
        }
        var trashed: [String] = [], failed: [String] = []
        for item in plan["trash"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            do { try AppStore.trashItem(URL(fileURLWithPath: item)); trashed.append(item) }
            catch { failed.append(item) }
        }
        let done = try await call("album.complete_archive",
            ["album_id": .int(id), "trashed": .array(trashed.map { .string($0) })])
        return .archived(archived: done["archived"]?.intValue ?? 0, blocked: blocked(), failed: failed)
    }

    // MARK: People

    public func getPeople() async {
        await guarded { people = try await call(PeopleLibrary.self, "people.bootstrap") }
    }

    public func getFaces(personId: Int?) async throws -> FaceCollection {
        try await call(FaceCollection.self, "person.faces", ["person_id": personId.map { .int($0) } ?? .null])
    }

    public func setPersonName(_ personId: Int, name: String) async {
        await guarded { _ = try await call("person.name", ["person_id": .int(personId), "name": .string(name)]) }
    }

    public func mergePerson(source: Int, target: Int) async {
        await guarded { _ = try await call("person.merge", ["source_id": .int(source), "target_id": .int(target)]) }
    }

    public func assignFace(_ faceId: Int, personId: Int?) async {
        await guarded {
            _ = try await call("face.assign", ["face_id": .int(faceId), "person_id": personId.map { .int($0) } ?? .null])
        }
    }

    /// Returns the new person id.
    @discardableResult
    public func createPersonFromFace(_ faceId: Int, name: String = "") async -> Int? {
        var id: Int?
        await guarded {
            id = try await call("face.create_person", ["face_id": .int(faceId), "name": .string(name)])["id"]?.intValue
        }
        return id
    }

    // MARK: Jobs

    /// main.cjs database:job-start; a finished job triggers App.tsx's bootstrap() reload.
    public func startDatabaseJob(kind: String, sources: [String] = []) async {
        guard ["index", "analyze"].contains(kind) else { error = "Неизвестный тип операции"; return }
        launch(kind: kind, sources: sources, albumId: nil, params: nil)
    }

    private func launch(kind: String, sources: [String], albumId: Int?, params: JSONValue?) {
        guard let database else { error = "База данных не выбрана"; return }
        do {
            try jobRunner.start(kind: kind, database: database, sources: sources, albumId: albumId, params: params) { [weak self] state in
                Task { @MainActor in self?.apply(state) }
            }
        } catch { self.error = AppStore.message(error) }
    }

    private func apply(_ state: JobState) {
        job = state
        if state.status == .complete { Task { await bootstrap() } }
    }

    public func cancelDatabaseJob() async {
        jobRunner.cancel()
        job.status = .cancelled
        job.stage = "Операция отменена"
        job.current = nil
        job.total = nil
    }

    // MARK: Layout

    private func encode(_ params: AppLayoutParams) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params))
    }

    public func layoutPreflight(albumId: Int, params: AppLayoutParams) async throws -> LayoutPreflight {
        var payload = try encode(params).objectValue ?? [:]
        payload["album_id"] = .int(albumId)
        return try await call(LayoutPreflight.self, "layout.preflight", .object(payload))
    }

    /// `layout.get` answers null for an album without layout.
    public func getLayout(albumId: Int) async throws -> Layout? {
        let value = try await call("layout.get", ["album_id": .int(albumId)])
        return value == .null ? nil : try AppModels.decode(Layout.self, value)
    }

    public func layoutTemplates(orientation: String, photoCount: Int) async throws -> [LayoutTemplateInfo] {
        try await call([LayoutTemplateInfo].self, "layout.templates",
            ["orientation": .string(orientation), "photo_count": .int(photoCount)])
    }

    public func startLayout(albumId: Int, params: AppLayoutParams) async {
        launch(kind: "layout", sources: [], albumId: albumId, params: try? encode(params))
    }

    public func layoutAlternatives(spreadId: Int, cellIndex: Int) async throws -> [LayoutAlternative] {
        try await call([LayoutAlternative].self, "layout.alternatives", ["spread_id": .int(spreadId), "cell_index": .int(cellIndex)])
    }

    public func layoutSimilar(spreadId: Int, cellIndex: Int) async throws -> [LayoutAlternative] {
        try await call([LayoutAlternative].self, "layout.similar", ["spread_id": .int(spreadId), "cell_index": .int(cellIndex)])
    }

    public func layoutVariants(spreadId: Int) async throws -> [LayoutVariant] {
        try await call([LayoutVariant].self, "layout.variants", ["spread_id": .int(spreadId)])
    }

    public func layoutSetPhoto(spreadId: Int, cellIndex: Int, imageId: Int) async throws -> Layout {
        try await call(Layout.self, "layout.set_photo",
            ["spread_id": .int(spreadId), "cell_index": .int(cellIndex), "image_id": .int(imageId)])
    }

    public func layoutSwapCells(spreadId: Int, cellA: Int, cellB: Int) async throws -> Layout {
        try await call(Layout.self, "layout.swap_cells", ["spread_id": .int(spreadId), "cell_a": .int(cellA), "cell_b": .int(cellB)])
    }

    public func layoutSetTemplate(spreadId: Int, templateId: String) async throws -> Layout {
        try await call(Layout.self, "layout.set_template", ["spread_id": .int(spreadId), "template_id": .string(templateId)])
    }

    public func layoutSetCrop(spreadId: Int, cellIndex: Int, crop: LayoutRect) async throws -> Layout {
        let c: JSONValue = ["x": .double(crop.x), "y": .double(crop.y), "w": .double(crop.w), "h": .double(crop.h)]
        return try await call(Layout.self, "layout.set_crop", ["spread_id": .int(spreadId), "cell_index": .int(cellIndex), "crop": c])
    }

    public func layoutRecompose(spreadId: Int, prompt: String?) async throws -> Layout {
        try await call(Layout.self, "layout.recompose_spread", ["spread_id": .int(spreadId), "prompt": .string(prompt ?? "")])
    }

    public func layoutApplyVariant(spreadId: Int, templateId: String, imageIds: [Int]) async throws -> Layout {
        try await call(Layout.self, "layout.apply_variant",
            ["spread_id": .int(spreadId), "template_id": .string(templateId), "image_ids": .array(imageIds.map { .int($0) })])
    }

    public func layoutParsePrompt(_ prompt: String) async throws -> LayoutPromptInfo {
        try await call(LayoutPromptInfo.self, "layout.parse_prompt", ["prompt": .string(prompt)])
    }

    /// main.cjs layout:export; nil when no folder is chosen. The view reveals `folder` in Finder.
    public func exportLayout(albumId: Int, chooseFolder: () async -> URL?) async throws -> JSONValue? {
        guard let folder = await chooseFolder() else { return nil }
        return try await call("layout.export", ["album_id": .int(albumId), "folder": .string(folder.standardizedFileURL.path)])
    }

    // MARK: Images

    /// Longest side that fits the oriented image into a box without upscaling.
    private nonisolated static func boxPixel(source: CGImageSource?, box: (w: Double, h: Double)) -> Int? {
        guard let source, let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
        let scale = min(box.w / w, box.h / h, 1)
        return max(1, Int((max(w, h) * scale).rounded()))
    }

    private nonisolated static func decodeImage(source: CGImageSource?, maxPixel: Int) -> CGImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func fileImage(imageId: Int, maxPixel: Int, box: (w: Double, h: Double)? = nil, key: String?) async -> CGImage? {
        if let key, let hit = cache.object(forKey: key as NSString) { return hit }
        guard let path = mediaPaths[imageId] else { return nil }
        let image = await Task.detached { () -> CGImage? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
            let side = box.flatMap { AppStore.boxPixel(source: source, box: $0) } ?? maxPixel
            return AppStore.decodeImage(source: source, maxPixel: side)
        }.value
        // The catalog was reloaded meanwhile: do not cache or return a stale image.
        guard mediaPaths[imageId] == path else { return nil }
        if let image, let key { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// Fits a 720x480 box, cached (limit 300).
    public func thumbnail(imageId: Int) async -> CGImage? {
        await fileImage(imageId: imageId, maxPixel: 720, box: (720, 480), key: "photo-\(imageId)")
    }

    public func original(imageId: Int) async -> CGImage? {
        await fileImage(imageId: imageId, maxPixel: 8192, key: nil)
    }

    public func faceThumbnail(faceId: Int) async -> CGImage? {
        let key = "face-\(faceId)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let result = try? await call("face.thumbnail", ["face_id": .int(faceId)]),
              let b64 = result["base64"]?.stringValue, let data = Data(base64Encoded: b64) else { return nil }
        let image = await Task.detached { () -> CGImage? in
            CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
