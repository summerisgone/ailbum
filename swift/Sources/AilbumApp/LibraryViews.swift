import AppKit
import AilbumCore
import SwiftUI
import UniformTypeIdentifiers

private let databaseKey = "ailbum.database"

@MainActor
final class LibraryModel: ObservableObject {
    @Published var database: String? = UserDefaults.standard.string(forKey: databaseKey)
    @Published var albums: [AlbumRow] = []
    @Published var tiles: [PhotoTile] = []
    @Published var selectedAlbum: Int?
    @Published var error: String?

    func setDatabase(_ path: String) {
        database = path
        UserDefaults.standard.set(path, forKey: databaseKey)
        selectedAlbum = nil
        reload()
    }

    func reload() {
        guard let database else { return }
        do {
            albums = try LibraryBrowser.albums(database: database)
            tiles = try LibraryBrowser.photos(database: database, albumId: selectedAlbum)
            error = nil
        } catch {
            albums = []; tiles = []
            self.error = "\(error)"
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["sqlite3", "sqlite", "db"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { setDatabase(url.path) }
    }

    func create() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite3") ?? .data]
        panel.nameFieldStringValue = "ailbum.sqlite3"
        if panel.runModal() == .OK, let url = panel.url {
            do { try LibraryBrowser.create(database: url.path); setDatabase(url.path) } catch { self.error = "\(error)" }
        }
    }
}

struct LibraryView: View {
    @StateObject private var model = LibraryModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedAlbum) {
                Text("Все фото").tag(Int?.none)
                ForEach(model.albums) { album in
                    VStack(alignment: .leading) {
                        Text(album.title)
                        Text("\(album.status) \(album.selected)/\(album.target)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(Int?.some(album.id))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if model.database == nil {
                Text("Откройте или создайте базу").foregroundStyle(.secondary)
            } else if let error = model.error {
                Text(error).foregroundStyle(.red)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(model.tiles) { ThumbnailView(tile: $0) }
                    }.padding(8)
                }
            }
        }
        .toolbar {
            Button("Открыть базу") { model.open() }
            Button("Создать базу") { model.create() }
        }
        .onChange(of: model.selectedAlbum) { _, _ in model.reload() }
        .onAppear { model.reload() }
    }
}

struct ThumbnailView: View {
    let tile: PhotoTile
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
            if tile.selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .blue).padding(4)
            }
        }
        .frame(width: 140, height: 140)
        .clipped()
        .task(id: tile.path) {
            guard let path = tile.path else { image = nil; return }
            image = await ThumbnailLoader.load(path: path)
        }
    }
}

private func downscaled(path: String, maxPixel: Int) -> NSImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Bounded decode: at most 4 concurrent 256 px decodes, cancelled tiles skip work, cache capped at 300 images.
enum ThumbnailLoader {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    static func load(path: String) async -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let cancelled = Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<NSImage?, Never>) in
                queue.addOperation {
                    if cancelled.isSet { c.resume(returning: nil); return }
                    let image = downscaled(path: path, maxPixel: 256)
                    if let image { cache.setObject(image, forKey: path as NSString) }
                    c.resume(returning: image)
                }
            }
        } onCancel: { cancelled.set() }
    }
}
