import AppKit
import AilbumCore
import SwiftUI
import UniformTypeIdentifiers

private let spacing: CGFloat = 12
private let sidePadding: CGFloat = 24

private func timeLabel(_ photo: Photo) -> String {
    guard let t = photo.taken_at, t.count >= 16 else { return "Время неизвестно" }
    let chars = Array(t)
    guard chars[10] == "T" || chars[10] == " " else { return "Время неизвестно" }
    return String(chars[11..<16])
}

private func scoreColor(_ score: Double?) -> Color {
    guard let score else { return .gray }
    return score >= 75 ? .green : score >= 55 ? .orange : .red
}

private struct GridRowModel: Identifiable {
    enum Kind {
        case header(story: Story, count: Int, selected: Int)
        case items([AilbumCore.GridItem])
    }
    let id: String
    let kind: Kind
}

struct PhotosSection: View {
    let store: AppStore

    @State private var query = ""
    @State private var targetDraft = ""
    @State private var jump: (storyId: Int, token: Int)?
    @State private var viewerId: Int?
    @State private var expanded: Set<String> = []
    @State private var highlighted: Int?
    @FocusState private var targetFocused: Bool

    init(store: AppStore) { self.store = store }

    private var library: Library? { store.library }

    private var photos: [Photo] {
        guard let library else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return library.photos }
        let ru = Locale(identifier: "ru")
        func has(_ s: String?) -> Bool { s?.lowercased(with: ru).contains(q) ?? false }
        return library.photos.filter { p in
            has(p.file_name) || has(p.story_title) || p.people_names.contains(where: has)
                || (p.scene_tags + p.object_tags).contains { has($0.label) }
        }
    }

    private var selected: [Photo] {
        (library?.photos ?? []).filter(\.favorite)
            .sorted { ($0.selection_position ?? Int.max) < ($1.selection_position ?? Int.max) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let error = store.error {
                HStack {
                    Text(error).foregroundStyle(.white)
                    Spacer()
                    Button { store.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white).help("Закрыть")
                }
                .padding(8).background(Color.red.opacity(0.8))
            }
            if let library, library.album != nil {
                collectionBar(library)
                grid(library)
                tray(library)
            } else {
                EmptyState(store: store, hasPhotos: !(library?.photos.isEmpty ?? true))
            }
        }
        .sheet(isPresented: Binding(get: { viewerId != nil }, set: { if !$0 { viewerId = nil } })) {
            PhotoViewer(store: store, photos: photos, photoId: $viewerId)
        }
        .onAppear { targetDraft = String(library?.target_count ?? 0) }
        .onChange(of: library?.target_count) { _, v in if !targetFocused { targetDraft = String(v ?? 0) } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Фото, человек или сюжет", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Очистить поиск")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 360)
            Spacer()
            HStack(spacing: 6) {
                Text("Нужно выбрать")
                TextField("", text: $targetDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.center)
                    .focused($targetFocused)
                    .disabled(library?.album == nil || store.readOnly)
                    .onChange(of: targetDraft) { _, v in
                        let digits = v.filter(\.isNumber)
                        if digits != v { targetDraft = digits }
                    }
                    .onSubmit { saveTarget() }
                    .onChange(of: targetFocused) { _, f in if !f { saveTarget() } }
                    .help("Целевое количество фотографий")
                Text("фото")
            }
            let target = library?.target_count ?? 0
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                Text("\(selected.count)").bold()
                Text("/ \(target)")
            }
            .foregroundStyle(selected.count >= max(target, 1) ? Color.green : Color.primary)
        }
        .padding(.horizontal, sidePadding).padding(.vertical, 10)
    }

    private func saveTarget() {
        guard library?.album != nil, !store.readOnly else { return }
        let parsed = min(999, max(1, Int(targetDraft) ?? 1))
        targetDraft = String(parsed)
        Task { await store.setTarget(parsed) }
    }

    private func collectionBar(_ library: Library) -> some View {
        HStack {
            Text("Последний анализ").font(.caption).foregroundStyle(.secondary)
            Text("\(photos.count) фото").bold()
            if !query.isEmpty { Text("из \(library.photos.count)").foregroundStyle(.secondary) }
            Spacer()
            HStack(spacing: 14) {
                Label("рекомендация", systemImage: "sparkles")
                Label("похожие кадры", systemImage: "square.3.layers.3d")
                Label("лица", systemImage: "person.2")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, sidePadding).padding(.bottom, 8)
    }

    // MARK: Grid

    private func rows(_ library: Library, columns: Int) -> [GridRowModel] {
        var counts: [Int: Int] = [:]
        for p in library.photos where p.favorite { counts[p.story_id ?? 0, default: 0] += 1 }
        var result: [GridRowModel] = []
        for section in PhotoGrouping.sections(photos: photos, stories: library.stories, expandedSeries: expanded) {
            result.append(GridRowModel(id: section.key, kind: .header(
                story: section.story, count: section.count, selected: counts[section.story.id] ?? 0)))
            var i = 0
            while i < section.items.count {
                let slice = Array(section.items[i..<min(i + columns, section.items.count)])
                result.append(GridRowModel(id: "\(section.story.id)-\(i)", kind: .items(slice)))
                i += columns
            }
        }
        return result
    }

    private func grid(_ library: Library) -> some View {
        GeometryReader { geo in
            let columns = PhotoGrouping.columnCount(width: geo.size.width)
            let cardWidth = max(150, (geo.size.width - sidePadding * 2 - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            if photos.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title2)
                    Text("Ничего не найдено")
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: spacing) {
                            ForEach(rows(library, columns: columns)) { row in
                                switch row.kind {
                                case .header(let story, let count, let sel):
                                    storyHeader(story, count: count, selected: sel)
                                        .id(row.id)
                                case .items(let items):
                                    HStack(alignment: .top, spacing: spacing) {
                                        ForEach(items.indices, id: \.self) { idx in
                                            card(items[idx]).frame(width: cardWidth)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, sidePadding).padding(.bottom, 16)
                    }
                    .onChange(of: jump?.token) { _, _ in
                        guard let jump else { return }
                        withAnimation { proxy.scrollTo("header-\(jump.storyId)", anchor: .top) }
                        highlighted = jump.storyId
                        Task {
                            try? await Task.sleep(for: .milliseconds(1400))
                            if highlighted == jump.storyId { highlighted = nil }
                        }
                    }
                }
            }
        }
    }

    private func storyHeader(_ story: Story, count: Int, selected: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(story.title).font(.headline)
                Text(PhotoGrouping.storyPeriodLabel(story)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                HStack(spacing: 4) { Text("Выбрано"); Text("\(selected)").bold() }
                    .foregroundStyle(selected > 0 ? Color.accentColor : Color.secondary)
                Text("\(count) фото").foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityLabel("Выбрано \(selected) из \(count) фотографий в событии")
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(highlighted == story.id ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.3), value: highlighted)
    }

    @ViewBuilder
    private func card(_ item: AilbumCore.GridItem) -> some View {
        switch item {
        case .stack(_, let seriesKey, let photos, let rep):
            PhotoCard(store: store, photo: rep, pending: store.pending.contains(rep.id), readOnly: store.readOnly,
                      stackSize: photos.count, seriesSize: nil, onCollapse: nil,
                      onToggle: { toggle(rep, $0) }, onOpen: { expanded.insert(seriesKey) })
        case .photo(_, let photo, let series):
            PhotoCard(store: store, photo: photo, pending: store.pending.contains(photo.id), readOnly: store.readOnly,
                      stackSize: nil, seriesSize: series?.size,
                      onCollapse: (series?.isFirst ?? false) ? { expanded.remove(series!.key) } : nil,
                      onToggle: { toggle(photo, $0) }, onOpen: { viewerId = photo.id })
        }
    }

    private func toggle(_ photo: Photo, _ favorite: Bool) {
        Task { await store.setFavorite(imageId: photo.id, favorite: favorite) }
    }

    // MARK: Tray

    private func tray(_ library: Library) -> some View {
        let target = max(library.target_count, 1)
        let progress = min(1.0, Double(selected.count) / Double(target))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "heart.fill")
                Text("Выбрано").bold()
                Text("\(selected.count) из \(library.target_count)").foregroundStyle(.secondary)
                Button(store.autofilling ? "Дополняем…" : "Дополнить автоматически") {
                    Task { await store.autofill() }
                }
                .disabled(store.readOnly || store.autofilling)
                Spacer()
                ProgressView(value: progress).frame(width: 180)
                    .accessibilityLabel("Выбрано \(Int((progress * 100).rounded()))%")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if selected.isEmpty {
                        Label("Добавляйте лучшие кадры кнопкой на фотографии", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(selected.enumerated()), id: \.element.id) { index, photo in
                        TrayThumb(store: store, photo: photo, index: index + 1,
                                  pending: store.pending.contains(photo.id), readOnly: store.readOnly,
                                  onJump: { jumpToStory(photo) }, onRemove: { toggle(photo, false) })
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, sidePadding).padding(.vertical, 10)
        .background(.bar)
    }

    private func jumpToStory(_ photo: Photo) {
        guard let id = photo.story_id else { return }
        query = ""
        jump = (id, (jump?.token ?? 0) + 1)
    }
}

// MARK: Thumbnail loading

private struct StoreImage: View {
    let store: AppStore
    let imageId: Int
    var fill = true
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1).resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            }
        }
        .clipped()
        .task(id: imageId) { image = await store.thumbnail(imageId: imageId) }
    }
}

// MARK: Card

private struct PhotoCard: View {
    let store: AppStore
    let photo: Photo
    let pending: Bool
    let readOnly: Bool
    let stackSize: Int?
    let seriesSize: Int?
    let onCollapse: (() -> Void)?
    let onToggle: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        let score = PhotoGrouping.score(photo)
        let aesthetic = photo.aesthetic_score.map { Int(($0 * 100).rounded()) }
        VStack(alignment: .leading, spacing: 6) {
            StoreImage(store: store, imageId: photo.id)
                .aspectRatio(PhotoGrouping.isPortrait(photo) ? 0.75 : 1.47, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    HStack {
                        Text(score.map { String(Int($0)) } ?? "\u{2014}")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(scoreColor(score), in: Capsule())
                            .help("Техническое качество" + (score.map { ": \(Int($0))" } ?? " не оценено"))
                        Spacer()
                        Button { onToggle(!photo.favorite) } label: {
                            if pending { ProgressView().controlSize(.small) }
                            else { Image(systemName: photo.favorite ? "checkmark" : "plus") }
                        }
                        .buttonStyle(.borderedProminent).tint(photo.favorite ? .accentColor : .black.opacity(0.5))
                        .disabled(pending || readOnly)
                        .help(photo.favorite ? "Убрать из выбранного" : "Добавить в выбранное")
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Spacer().frame(height: 34)
                        if let n = stackSize {
                            Label("\(n)", systemImage: "square.3.layers.3d")
                                .font(.caption.bold()).padding(4).background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white).help("Серия из \(n) похожих фотографий")
                        }
                        if let onCollapse {
                            Button(action: onCollapse) { Label("Свернуть", systemImage: "square.3.layers.3d") }
                                .font(.caption).buttonStyle(.bordered).controlSize(.small)
                                .help("Свернуть серию")
                                .accessibilityLabel("Свернуть серию из \(seriesSize ?? 0) фотографий")
                        }
                    }.padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.availability != .present {
                        Text(photo.availability == .missing ? "нет файла" : "архив")
                            .font(.caption2).padding(4).background(.black.opacity(0.7), in: Capsule())
                            .foregroundStyle(.white).padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) { flags(aesthetic).padding(6) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(photo.favorite ? Color.accentColor : .clear, lineWidth: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(stackSize != nil ? "Серия \u{00B7} \(photo.file_name)" : photo.file_name)
                    .font(.callout.bold()).lineLimit(1).help(photo.file_name)
                Text(timeLabel(photo)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stackSize.map { "Раскрыть серию из \($0) фотографий" } ?? "Открыть \(photo.file_name)")
    }

    private func flags(_ aesthetic: Int?) -> some View {
        HStack(spacing: 4) {
            if photo.auto_selected { chip("sparkles", nil, "Рекомендовано анализатором") }
            if let c = photo.similar_cluster { chip("square.3.layers.3d", nil, "Группа похожих №\(c)") }
            if photo.face_count > 0 { chip("person.2", "\(photo.face_count)", "\(photo.face_count) лиц") }
            if photo.smiling_faces_count > 0 { chip("face.smiling", nil, "Есть улыбки") }
            if photo.closed_eyes_count > 0 { chip("eye.slash", nil, "Обнаружены закрытые глаза", warn: true) }
            if let a = aesthetic { chip("sparkles", "\(a)", "CLIP-оценка эстетики: \(a)") }
            if let t = photo.scene_tags.first {
                Text(t.label).font(.caption2).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                    .help("Сюжет: " + photo.scene_tags.map(\.label).joined(separator: ", "))
            }
        }
    }

    private func chip(_ symbol: String, _ text: String?, _ help: String, warn: Bool = false) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            if let text { Text(text) }
        }
        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
        .background(warn ? Color.orange.opacity(0.85) : .black.opacity(0.6), in: Capsule())
        .foregroundStyle(.white).help(help)
    }
}

private struct TrayThumb: View {
    let store: AppStore
    let photo: Photo
    let index: Int
    let pending: Bool
    let readOnly: Bool
    let onJump: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onJump) {
                StoreImage(store: store, imageId: photo.id)
                    .frame(width: PhotoGrouping.isPortrait(photo) ? 52 : 88, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomLeading) {
                        Text("\(index)").font(.caption2.bold()).padding(3)
                            .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white).padding(3)
                    }
            }
            .buttonStyle(.plain)
            .help("Перейти к сюжету: " + ((photo.story_title?.isEmpty ?? true) ? "Без названия" : photo.story_title!))
            .accessibilityLabel("Перейти к \(photo.file_name) в сетке")
            Button(action: onRemove) {
                if pending { ProgressView().controlSize(.mini) } else { Image(systemName: "xmark") }
            }
            .buttonStyle(.plain).font(.caption2).padding(4)
            .background(.black.opacity(0.7), in: Circle()).foregroundStyle(.white)
            .padding(3).disabled(pending || readOnly)
            .help("Убрать из выбранного")
            .accessibilityLabel("Убрать \(photo.file_name)")
        }
    }
}

// MARK: Viewer

private struct PhotoViewer: View {
    let store: AppStore
    let photos: [Photo]
    @Binding var photoId: Int?
    @State private var image: CGImage?
    @Environment(\.dismiss) private var dismiss

    private var index: Int? { photos.firstIndex { $0.id == photoId } }

    var body: some View {
        Group {
            if let index {
                content(photos[index], index: index)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    private func go(_ delta: Int) {
        guard let index, photos.indices.contains(index + delta) else { return }
        photoId = photos[index + delta].id
    }

    private func content(_ photo: Photo, index: Int) -> some View {
        let label = PhotoGrouping.dateLabel(PhotoGrouping.dateOf(photo))
        let score = PhotoGrouping.score(photo)
        let pending = store.pending.contains(photo.id)
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.file_name).bold().textSelection(.enabled).help("Имя файла можно выделить и скопировать")
                    Text((photo.story_title.map { $0.isEmpty ? "" : "\($0) \u{00B7} " } ?? "")
                         + label.date + (label.weekday.isEmpty ? "" : " \u{00B7} \(label.weekday)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.setFavorite(imageId: photo.id, favorite: !photo.favorite) }
                } label: {
                    if pending { ProgressView().controlSize(.small) }
                    else { Image(systemName: photo.favorite ? "checkmark" : "plus") }
                    Text(photo.favorite ? "Выбрано" : "Выбрать")
                }
                .disabled(pending || store.readOnly)
                .help(photo.favorite ? "Убрать из выбранного" : "Добавить в выбранное")
                if photo.availability == .missing {
                    Button("Подтвердить удаление") { Task { await store.confirmMissing(imageId: photo.id) } }
                }
                if let score { Text("Качество \(Int(score))") }
                Text("\(index + 1) / \(photos.count)").foregroundStyle(.secondary)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction).help("Закрыть (Esc)")
                    .accessibilityLabel("Закрыть просмотр")
            }
            .padding(12)
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
                HStack {
                    Button { go(-1) } label: { Image(systemName: "chevron.left").font(.title) }
                        .disabled(index == 0).keyboardShortcut(.leftArrow, modifiers: [])
                        .help("Предыдущее фото (\u{2190})").accessibilityLabel("Предыдущее фото")
                    Spacer()
                    Button { go(1) } label: { Image(systemName: "chevron.right").font(.title) }
                        .disabled(index >= photos.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                        .help("Следующее фото (\u{2192})").accessibilityLabel("Следующее фото")
                }
                .buttonStyle(.plain).foregroundStyle(.white).padding(16)
            }
        }
        .task(id: photo.id) {
            image = nil
            image = await store.original(imageId: photo.id)
        }
    }
}

// MARK: Empty state

private struct EmptyState: View {
    let store: AppStore
    let hasPhotos: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(hasPhotos ? "Сначала запустите анализ" : "В каталоге пока нет фотографий").font(.title2.bold())
            Text(hasPhotos
                 ? "Фотографии проиндексированы, но для скоринга и отбора нужен завершённый запуск CLI."
                 : "Выберите SQLite-каталог Ailbum или проиндексируйте папку через CLI.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Выбрать базу") { choose() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["sqlite3", "sqlite", "db"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.openDatabase(path: url.path) }
        }
    }
}
