import AilbumCore
import SwiftUI

enum AppSectionID: String, CaseIterable, Identifiable {
    case photos, albums, people, layout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photos: "Отбор фотографий"
        case .albums: "Альбомы"
        case .people: "Люди и лица"
        case .layout: "Раскладка"
        }
    }
    var icon: String {
        switch self {
        case .photos: "photo.on.rectangle"
        case .albums: "folder"
        case .people: "person.2"
        case .layout: "square.grid.2x2"
        }
    }
}

struct AppShell: View {
    @State private var store: AppStore
    @State private var section: AppSectionID? = .photos
    @State private var settingsOpen = false

    init() {
        let env = ProcessInfo.processInfo.environment
        _store = State(initialValue: AppStore(
            database: env["AILBUM_DATABASE"],
            jobRunner: JobRunner(executable: AppShell.resolveExecutable())))
    }

    /// Next to the app binary, then its parent (.build sibling), then PATH.
    static func resolveExecutable() -> URL {
        let fm = FileManager.default
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
        let candidates = [exe, exe.deletingLastPathComponent()].map { $0.appendingPathComponent("ailbum-swift") }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent("ailbum-swift") }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) } ?? JobRunner.defaultExecutable()
    }

    private var current: AppSectionID { section ?? .photos }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(AppSectionID.allCases, selection: $section) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                Divider()
                Button { settingsOpen = true } label: {
                    HStack {
                        Label("Базы данных и анализ", systemImage: "gearshape")
                        if store.job.status == .running { Circle().fill(.orange).frame(width: 8, height: 8) }
                        Spacer()
                    }
                    .padding(10)
                }
                .buttonStyle(.plain)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                header
                banners
                detail
            }
        }
        .task { await store.bootstrap(albumId: nil) }
        .sheet(isPresented: $settingsOpen) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Закрыть") { settingsOpen = false }.keyboardShortcut(.cancelAction)
                }.padding(10)
                DatabaseSection(store: store)
            }
            .frame(minWidth: 640, minHeight: 480)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(current.title).font(.title2.bold())
            Button {
                settingsOpen = true
            } label: {
                Label(store.library?.database.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "Каталог",
                      systemImage: "cylinder")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help(store.library?.database ?? "")
            Spacer()
            if !store.albums.isEmpty {
                Picker("Альбом", selection: Binding(
                    get: { store.albumId ?? -1 },
                    set: { id in if id >= 0 { Task { await store.openAlbum(id) } } })
                ) {
                    if store.albumId == nil { Text("Альбом").tag(-1) }
                    ForEach(store.albums, id: \.id) { Text($0.title).tag($0.id) }
                }
                .frame(maxWidth: 240)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var banners: some View {
        if let message = store.error {
            HStack {
                Text(message).lineLimit(3)
                Spacer()
                Button { store.error = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Закрыть")
            }
            .padding(10).background(.red.opacity(0.15))
        }
        if store.job.status == .running {
            VStack(alignment: .leading, spacing: 4) {
                Text([store.job.stage, store.job.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - "))
                    .font(.caption)
                if let c = store.job.current, let t = store.job.total, t > 0 {
                    ProgressView(value: Double(c), total: Double(t))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        if store.readOnly, let album = store.library?.album, current != .albums {
            HStack {
                Text(album.status == .ordered
                    ? "Альбом заказан - только просмотр"
                    : "Альбом в архиве - только просмотр")
                Spacer()
                if album.status == .ordered {
                    Button("Вернуть в работу") { Task { await store.setAlbumStatus(album.id, status: .draft) } }
                        .disabled(store.albumBusy)
                }
            }
            .padding(10).background(.yellow.opacity(0.15))
        }
    }

    @ViewBuilder private var detail: some View {
        switch current {
        case .photos: PhotosSection(store: store)
        case .albums: AlbumsSection(store: store)
        case .people: PeopleSection(store: store)
        case .layout: LayoutSection(store: store)
        }
    }
}
