import AppKit
import AilbumCore
import SwiftUI

struct AlbumsSection: View {
    let store: AppStore

    init(store: AppStore) { self.store = store }

    private static let groups: [(AlbumStatus, String)] = [
        (.draft, "Черновики"), (.ordered, "Заказаны"), (.archived, "В архиве"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note = store.archiveNote { ArchiveNote(note: note) }
                ForEach(Self.groups, id: \.0) { status, title in
                    let items = store.albums.filter { $0.status == status }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(title).font(.headline)
                            Text("\(items.count)").foregroundStyle(.secondary)
                        }
                        if items.isEmpty {
                            Text("Пусто").foregroundStyle(.secondary)
                        } else {
                            ForEach(items, id: \.id) { album in
                                AlbumCard(store: store, album: album, active: album.id == store.albumId)
                            }
                        }
                    }
                }
                if let usage = store.usage { UsageFooter(usage: usage) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.listAlbums() }
    }
}

private func megabytes(_ bytes: Int) -> String { String(format: "%.1f МБ", Double(bytes) / 1048576) }

private func confirm(_ text: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = text
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Отмена")
    return alert.runModal() == .alertFirstButtonReturn
}

@MainActor
private func chooseArchiveFolder() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Куда сохранить оригиналы перед удалением"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}

private struct UsageFooter: View {
    let usage: Usage
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("База: \(megabytes(usage.database_bytes))")
            Text("Превью: \(megabytes(usage.proxies_bytes))")
            Text("Кэш признаков: \(megabytes(usage.feature_cache_bytes))")
            Text("Фото: \(usage.images.present) на месте, \(usage.images.missing) без файла, \(usage.images.archived) в архиве")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct ArchiveNote: View {
    let note: ArchiveResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch note {
            case .archived(let archived, let blocked, let failed):
                Text("Архивировано фото: \(archived)").bold()
                ForEach(Array(blocked.enumerated()), id: \.offset) { _, item in
                    Text("Фото \(item.image_id): \(item.reason)")
                }
                ForEach(failed, id: \.self) { Text("Не удалось: \($0)") }
            case .needsExport(let blocked):
                Text("Нужен экспорт").bold()
                ForEach(Array(blocked.enumerated()), id: \.offset) { _, item in
                    Text("Фото \(item.image_id): \(item.reason)")
                }
            case .cancelled:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AlbumCard: View {
    let store: AppStore
    let album: Album
    let active: Bool
    @State private var editing = false
    @State private var title = ""
    @FocusState private var focused: Bool

    private func day(_ value: String?) -> String { value.map { String($0.prefix(10)) } ?? "" }

    private var dates: String {
        [
            "изменён \(day(album.updated_at))",
            album.ordered_at.map { "заказан \(day($0))" } ?? "",
            album.archived_at.map { "в архиве \(day($0))" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func commit() {
        let next = title.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !next.isEmpty && next != album.title {
            Task { await store.renameAlbum(album.id, title: next) }
        } else {
            title = album.title
        }
    }

    var body: some View {
        let busy = store.albumBusy
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if editing {
                    TextField("Название альбома", text: $title)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { title = album.title; editing = false }
                        .onChange(of: focused) { _, now in if !now && editing { commit() } }
                } else {
                    Text(album.title).bold()
                        .help(album.status == .draft ? "Двойной щелчок - переименовать" : "")
                        .onTapGesture(count: 2) {
                            guard album.status == .draft, !busy else { return }
                            title = album.title
                            editing = true
                            focused = true
                        }
                }
                Spacer()
                Text("\(album.photo_count) из \(album.target_count)").foregroundStyle(.secondary)
            }
            Text(album.sources.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                .font(.footnote).foregroundStyle(.secondary)
            Text(dates).font(.footnote).foregroundStyle(.secondary)
            if album.status == .archived {
                Text("Оригиналы в Корзине, превью сохранены").font(.footnote)
            }
            HStack {
                Button("Открыть") { Task { await store.openAlbum(album.id) } }.disabled(busy)
                switch album.status {
                case .draft:
                    Button("Отметить заказанным") { Task { await store.setAlbumStatus(album.id, status: .ordered) } }.disabled(busy)
                    Button("Удалить черновик", role: .destructive) {
                        if confirm("Удалить черновик «\(album.title)»?") {
                            Task { await store.deleteAlbum(album.id, forgetDecisions: false) }
                        }
                    }.disabled(busy)
                case .ordered:
                    Button("Вернуть в работу") { Task { await store.setAlbumStatus(album.id, status: .draft) } }.disabled(busy)
                    Button("Освободить место") {
                        let text = "Освободить место для «\(album.title)»? Экспорт будет проверен, построятся превью, оригиналы уйдут в Корзину (\(album.photo_count) фото)."
                        if confirm(text) {
                            Task { await store.archiveAlbum(album.id, chooseFolder: chooseArchiveFolder) }
                        }
                    }.disabled(busy)
                case .archived:
                    Button("Удалить", role: .destructive) {
                        if confirm("Удалить альбом «\(album.title)»? Решения по фото (выбор и обучение) будут забыты.") {
                            Task { await store.deleteAlbum(album.id, forgetDecisions: true) }
                        }
                    }.disabled(busy)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: active ? 2 : 1))
    }
}
