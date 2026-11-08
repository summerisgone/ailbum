import AilbumCore
import AppKit
import SwiftUI

private typealias AlbumLayout = AilbumCore.Layout

let layoutWarningLabels: [String: String] = [
    "face_cut": "Лицо обрезано",
    "face_on_spine": "Лицо на корешке",
    "merged_stories": "Объединены сюжеты",
    "underfilled": "Мало кадров",
]

func layoutWarningText(_ key: String) -> String { layoutWarningLabels[key] ?? key }

/// Keeps the crop window inside the photo; a degenerate size falls back to the whole frame.
func normalizedCrop(_ crop: LayoutRect) -> LayoutRect {
    let w = crop.w > 0 && crop.w <= 1 ? crop.w : 1
    let h = crop.h > 0 && crop.h <= 1 ? crop.h : 1
    var out = crop
    out.w = w
    out.h = h
    out.x = min(1 - w, max(0, crop.x))
    out.y = min(1 - h, max(0, crop.y))
    return out
}

// MARK: Section

struct LayoutSection: View {
    @Bindable var store: AppStore
    @State private var layout: AlbumLayout?
    @State private var loaded = false
    @State private var wizardOpen = false
    @State private var guides = false
    @State private var confirmReplace: AppLayoutParams?
    @State private var editing: Int?
    @State private var preview: PreviewMode?
    @State private var notice: String?
    @State private var exporting = false

    init(store: AppStore) { self.store = store }

    private var running: Bool { store.job.status == .running }
    private var layoutRunning: Bool { running && store.job.kind == "layout" }

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                jobStrip
                content
            }
        }
        .task(id: store.albumId) {
            loaded = false
            layout = nil
            wizardOpen = false
            await load()
        }
        .onChange(of: store.job.status) { _, status in
            if status == .complete && store.job.kind == "layout" { Task { await load() } }
        }
        .confirmationDialog("Заменить текущую раскладку?", isPresented: Binding(
            get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } })
        ) {
            Button("Заменить") {
                if let params = confirmReplace, let id = store.albumId { Task { await store.startLayout(albumId: id, params: params) } }
                confirmReplace = nil
            }
            Button("Отмена", role: .cancel) { confirmReplace = nil }
        }
        .sheet(item: editTarget) { target in editorSheet(target) }
        .onChange(of: editing) { _, value in
            if value == nil { Task { await load() } }
        }
        .sheet(item: $preview) { mode in
            if let layout { AlbumPreview(store: store, layout: layout, mode: mode, startSpread: 0) }
        }
    }

    private var editTarget: Binding<EditTarget?> {
        Binding(get: { editing.map { EditTarget(id: $0) } }, set: { if $0 == nil { editing = nil } })
    }

    @ViewBuilder private func editorSheet(_ target: EditTarget) -> some View {
        if let spread = layout?.spreads.first(where: { $0.id == target.id }) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Закрыть") { editing = nil }.keyboardShortcut(.cancelAction) }.padding(8)
                LayoutEditor(store: store, spread: spread, aspect: layout.map { $0.format.spread_w_mm / $0.format.spread_h_mm } ?? 1.5)
            }
            .frame(minWidth: 900, minHeight: 640)
        }
    }

    private func load() async {
        guard let id = store.albumId else { loaded = true; return }
        do {
            let next = try await store.getLayout(albumId: id)
            layout = next
            if next != nil { wizardOpen = false }
        } catch { store.error = String(describing: error) }
        loaded = true
    }

    @ViewBuilder private var jobStrip: some View {
        if running {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(layoutRunning ? (store.job.stage ?? "Создание раскладки") : "Идёт анализ, раскладка недоступна").bold()
                    if layoutRunning && !store.job.detail.isEmpty { Text(store.job.detail).foregroundStyle(.secondary) }
                }
                if layoutRunning {
                    if let total = store.job.total, total > 0 {
                        ProgressView(value: min(1, Double(store.job.current ?? 0) / Double(total)))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            .font(.caption).padding(.horizontal, 22).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading).background(Color.green.opacity(0.1))
        }
        if store.job.status == .error, store.job.kind == "layout", let message = store.job.error {
            Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 22).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.1))
        }
    }

    @ViewBuilder private var content: some View {
        if store.readOnly && layout == nil {
            Text("Альбом заказан - раскладка недоступна").font(.title3.bold()).padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let layout, !wizardOpen {
            viewer(layout)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Создать раскладку").font(.title3.bold())
                    if layout != nil { Text("Новая раскладка заменит текущую.").font(.caption).foregroundStyle(.secondary) }
                    LayoutWizard(store: store, busy: running, replacing: layout != nil,
                                 onCreate: { params in
                                     if layout != nil { confirmReplace = params }
                                     else if let id = store.albumId { Task { await store.startLayout(albumId: id, params: params) } }
                                 },
                                 onCancel: layout != nil ? { wizardOpen = false } : nil)
                        .padding(.top, 12)
                }
                .padding(28).frame(maxWidth: 980).frame(maxWidth: .infinity)
            }
        }
    }

    private func viewer(_ layout: AlbumLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if layout.stale {
                    banner { Text("Выбор изменился, пересоздать?"); Button("Пересоздать") { wizardOpen = true }.disabled(store.readOnly) }
                }
                if !layout.warnings.isEmpty {
                    banner { Text(layout.warnings.map(layoutWarningText).joined(separator: "; ")) }
                }
                if !layout.unplaced.isEmpty { banner { Text("Не поместилось кадров: \(layout.unplaced.count)") } }
                if let notice {
                    banner { Text(notice); Button("Закрыть") { self.notice = nil } }
                }
                HStack(spacing: 10) {
                    Toggle("Направляющие", isOn: $guides)
                    Button("Новая раскладка") { wizardOpen = true }.disabled(store.readOnly)
                    Button { preview = .book } label: { Label("Альбом", systemImage: "book") }
                    Button { preview = .actual } label: { Label("1:1", systemImage: "ruler") }
                        .help("Разворот в натуральную величину")
                    Button { Task { await export(layout) } } label: { Label("Экспорт оригиналов", systemImage: "square.and.arrow.down") }
                        .disabled(exporting)
                    Text("Нажмите ячейку, чтобы изменить разворот").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(layout.spreads, id: \.id) { spread in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(spread.story_title).bold()
                            Text("Разворот \(spread.position)").foregroundStyle(.secondary)
                            ForEach(spread.warnings, id: \.self) { Text(layoutWarningText($0)).font(.caption2).padding(3).background(Color.orange.opacity(0.25), in: .rect(cornerRadius: 4)) }
                        }
                        SpreadView(store: store, spread: spread, onSelectCell: { _ in editing = spread.id },
                                   aspect: layout.format.spread_w_mm / layout.format.spread_h_mm,
                                   guides: guides ? layout.format : nil)
                        if let reason = spread.assistant_reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(22)
        }
    }

    private func banner<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        HStack { body() }.font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15), in: .rect(cornerRadius: 8))
    }

    private func export(_ layout: AlbumLayout) async {
        exporting = true
        defer { exporting = false }
        do {
            let result = try await store.exportLayout(albumId: layout.album_id) {
                await MainActor.run {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    return panel.runModal() == .OK ? panel.url : nil
                }
            }
            guard let result else { return }
            let count = result["count"]?.intValue ?? 0
            let folder = result["folder"]?.stringValue ?? ""
            let missing = result["missing"]?.arrayValue?.count ?? 0
            notice = "Сохранено фото: \(count) в \(folder)" + (missing > 0 ? ". Не найдено файлов: \(missing)" : "")
            if !folder.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
        } catch { store.error = String(describing: error) }
    }
}

private struct EditTarget: Identifiable { let id: Int }

// MARK: Wizard

private struct PreflightKey: Hashable {
    var orientation: LayoutOrientation
    var spreads: Int
    var min: Int
    var max: Int
}

private struct LayoutWizard: View {
    let store: AppStore
    let busy: Bool
    let replacing: Bool
    let onCreate: (AppLayoutParams) -> Void
    let onCancel: (() -> Void)?

    @State private var orientation: LayoutOrientation = .vertical
    @State private var spreads = "4"
    @State private var minPhotos = "3"
    @State private var maxPhotos = "6"
    @State private var assistant: AssistantMode = .auto
    @State private var prompt = ""
    @State private var labels: [String] = []
    @State private var preflight: LayoutPreflight?
    @State private var loading = false

    private static func parseCount(_ value: String) -> Int? {
        let t = value.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(t) : nil
    }

    private var key: PreflightKey? {
        guard let s = Self.parseCount(spreads), let a = Self.parseCount(minPhotos), let b = Self.parseCount(maxPhotos) else { return nil }
        return PreflightKey(orientation: orientation, spreads: s, min: a, max: b)
    }

    private var ready: Bool { key != nil && !loading && (preflight?.errors.isEmpty ?? false) && !busy }

    var body: some View {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = key == nil ? ["Введите целые числа"] : preflight?.errors ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                step(1, "Ориентация") {
                    HStack {
                        orientationCard(.vertical, "Вертикальная", "210 x 297 мм")
                        orientationCard(.horizontal, "Горизонтальная", "297 x 210 мм")
                    }
                }
                step(2, "Число разворотов") {
                    HStack {
                        TextField("", text: $spreads).frame(width: 72).multilineTextAlignment(.center)
                            .accessibilityLabel("Число разворотов")
                        if let preflight {
                            let hint = max(1, preflight.unit_count / 4)
                            Button("Подсказка: \(hint)") { spreads = String(hint) }.font(.caption)
                        }
                    }
                }
                step(3, "Фото на коллаже") {
                    HStack {
                        TextField("", text: $minPhotos).frame(width: 72).multilineTextAlignment(.center)
                            .accessibilityLabel("Минимум фото")
                        Text("-")
                        TextField("", text: $maxPhotos).frame(width: 72).multilineTextAlignment(.center)
                            .accessibilityLabel("Максимум фото")
                    }
                    Picker("AI-редактор", selection: $assistant) {
                        Text("Авто").tag(AssistantMode.auto)
                        Text("Выключен").tag(AssistantMode.off)
                    }
                }
            }
            card {
                Text("Пожелание сборщику").font(.headline)
                TextField("Например: приоритет лицам и крупным планам, меньше пейзажей", text: $prompt, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                if !trimmed.isEmpty {
                    Text(labels.isEmpty
                         ? "Сборщик не распознал пожелание: укажите лица, крупные планы или пейзажи. AI-редактор получит текст как есть."
                         : "Понято: \(labels.joined(separator: ", ")). Текст пожелания также получит AI-редактор.")
                        .font(.caption).foregroundStyle(labels.isEmpty ? Color.orange : Color.green)
                }
            }
            card {
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    if let preflight {
                        Text("\(preflight.unit_count) кадров, \(preflight.story_count) сюжетов, нужно \(preflight.min_needed)-\(preflight.max_used)").bold()
                    } else { Text("Расчёт...").bold() }
                }
                ForEach(Array(errors.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.red) }
                if key != nil, let preflight {
                    ForEach(Array(preflight.warnings.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange) }
                    ForEach(Array(preflight.allocation.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text("\(item.units) кадров").font(.caption2).foregroundStyle(.secondary)
                            Text("\(item.spreads)").bold().frame(minWidth: 24, alignment: .trailing)
                        }
                    }
                }
                HStack {
                    Spacer()
                    if let onCancel { Button("Отмена", action: onCancel) }
                    Button(replacing ? "Создать заново" : "Создать") {
                        guard let key, ready else { return }
                        onCreate(AppLayoutParams(orientation: key.orientation, spread_count: key.spreads, min_photos: key.min,
                                                 max_photos: key.max, assistant: assistant, prompt: trimmed))
                    }
                    .buttonStyle(.borderedProminent).disabled(!ready)
                }
            }
        }
        .task(id: key) {
            guard let key, let albumId = store.albumId else { preflight = nil; loading = false; return }
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await store.layoutPreflight(
                    albumId: albumId,
                    params: AppLayoutParams(orientation: key.orientation, spread_count: key.spreads, min_photos: key.min, max_photos: key.max))
                preflight = result
                loading = false
            } catch is CancellationError {
            } catch {
                loading = false
                store.error = String(describing: error)
            }
        }
        .task(id: prompt) {
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { labels = []; return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                labels = try await store.layoutParsePrompt(prompt).labels
            } catch is CancellationError {
            } catch { labels = [] }
        }
    }

    private func orientationCard(_ value: LayoutOrientation, _ title: String, _ size: String) -> some View {
        Button { orientation = value } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).stroke(Color.secondary, lineWidth: 2)
                    .frame(width: value == .vertical ? 28 : 40, height: value == .vertical ? 40 : 28)
                Text(title).font(.caption.bold())
                Text(size).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12).padding(.horizontal, 6).frame(maxWidth: .infinity)
            .background(orientation == value ? Color.green.opacity(0.15) : Color.gray.opacity(0.08), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(orientation == value ? Color.green : Color.gray.opacity(0.3)))
        }
        .buttonStyle(.plain)
    }

    private func step<C: View>(_ number: Int, _ title: String, @ViewBuilder _ body: () -> C) -> some View {
        card {
            Text("\(number)").font(.caption2.bold()).frame(width: 22, height: 22)
                .background(Color.green.opacity(0.2), in: .rect(cornerRadius: 7))
            Text(title).font(.headline)
            body()
        }
    }

    private func card<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { body() }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.25)))
    }
}

// MARK: Spread view

/// Image stretched into a cell so that only the crop window shows; crop and cell are normalized.
struct CroppedPhoto: View {
    let image: CGImage?
    let crop: LayoutRect

    var body: some View {
        GeometryReader { geo in
            let c = normalizedCrop(crop)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: geo.size.width / c.w, height: geo.size.height / c.h)
                        .offset(x: -c.x * geo.size.width / c.w, y: -c.y * geo.size.height / c.h)
                } else {
                    Color.gray.opacity(0.15)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading).clipped()
        }
    }
}

struct SpreadView: View {
    let store: AppStore
    let spread: LayoutSpread
    let onSelectCell: (Int) -> Void
    var aspect: Double = 2 * 210.0 / 297.0
    var guides: LayoutFormat?

    init(store: AppStore, spread: LayoutSpread, onSelectCell: @escaping (Int) -> Void,
         aspect: Double = 2 * 210.0 / 297.0, guides: LayoutFormat? = nil) {
        self.store = store
        self.spread = spread
        self.onSelectCell = onSelectCell
        self.aspect = aspect
        self.guides = guides
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Color.white
                ForEach(spread.cells, id: \.index) { cell in
                    SpreadCellView(store: store, cell: cell)
                        .frame(width: cell.w * w, height: cell.h * h)
                        .offset(x: cell.x * w, y: cell.y * h)
                        .onTapGesture { onSelectCell(cell.index) }
                }
                if let f = guides {
                    Rectangle().stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .frame(width: w * (1 - 2 * f.bleed_mm / f.spread_w_mm), height: h * (1 - 2 * f.bleed_mm / f.spread_h_mm))
                        .offset(x: w * f.bleed_mm / f.spread_w_mm, y: h * f.bleed_mm / f.spread_h_mm).allowsHitTesting(false)
                    let inset = f.bleed_mm + f.safe_mm
                    Rectangle().stroke(Color.green.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4]))
                        .frame(width: w * (1 - 2 * inset / f.spread_w_mm), height: h * (1 - 2 * inset / f.spread_h_mm))
                        .offset(x: w * inset / f.spread_w_mm, y: h * inset / f.spread_h_mm).allowsHitTesting(false)
                    Rectangle().fill(Color.blue.opacity(0.15))
                        .frame(width: w * 16 / f.spread_w_mm, height: h)
                        .offset(x: w * (f.spread_w_mm / 2 - 8) / f.spread_w_mm).allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading).clipped()
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay(Rectangle().stroke(Color.gray.opacity(0.4)))
    }
}

private struct SpreadCellView: View {
    let store: AppStore
    let cell: LayoutCell
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let placement = cell.placement {
                CroppedPhoto(image: image, crop: placement.crop)
                    .task(id: placement.image_id) { image = await store.thumbnail(imageId: placement.image_id) }
                VStack(alignment: .leading, spacing: 2) {
                    if placement.replaced_image_id != nil { badge("Из похожих", .blue) }
                    if !placement.warnings.isEmpty { badge(placement.warnings.map(layoutWarningText).joined(separator: ", "), .orange) }
                }
                .padding(4)
            } else {
                Color.gray.opacity(0.12)
                Text("Пусто").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.85), in: .rect(cornerRadius: 4)).foregroundStyle(.white)
    }
}

// MARK: Album preview

enum PreviewMode: String, Identifiable { case book, actual; var id: String { rawValue } }

private struct AlbumPreview: View {
    let store: AppStore
    let layout: AlbumLayout
    let mode: PreviewMode
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int
    @State private var pxPerMm: Double
    @State private var calibrating = false

    private static let scaleKey = "ailbum.layout.pxPerMm"
    private static let cardW = 85.6, cardH = 53.98

    init(store: AppStore, layout: AlbumLayout, mode: PreviewMode, startSpread: Int) {
        self.store = store
        self.layout = layout
        self.mode = mode
        _page = State(initialValue: mode == .book ? startSpread + 1 : startSpread)
        let saved = UserDefaults.standard.double(forKey: Self.scaleKey)
        _pxPerMm = State(initialValue: saved > 1 && saved < 20 ? saved : 127.0 / 25.4)
    }

    private var book: Bool { mode == .book }
    private var last: Int { book ? layout.spreads.count + 1 : layout.spreads.count - 1 }
    private var spread: LayoutSpread? {
        let i = book ? page - 1 : page
        return layout.spreads.indices.contains(i) ? layout.spreads[i] : nil
    }
    private var title: String {
        book ? (page == 0 ? "Обложка" : page == last ? "Задняя обложка" : "Разворот \(page) из \(layout.spreads.count)")
             : "Разворот \(page + 1) из \(layout.spreads.count)"
    }

    var body: some View {
        let f = layout.format
        let trimW = f.spread_w_mm - 2 * f.bleed_mm, trimH = f.spread_h_mm - 2 * f.bleed_mm
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(book ? "Альбом" : "Натуральная величина").bold()
                    Text(title + (spread.map { $0.story_title.isEmpty ? "" : " · \($0.story_title)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !book {
                    Button("Калибровка") { calibrating.toggle() }
                    if calibrating {
                        Button { scale(1 / 1.01) } label: { Image(systemName: "minus") }.help("Меньше")
                        Button { scale(1.01) } label: { Image(systemName: "plus") }.help("Больше")
                    }
                }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).help("Закрыть (Esc)")
            }
            .padding(12)
            if !book && calibrating {
                VStack {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.secondary, lineWidth: 2)
                        .frame(width: Self.cardW * pxPerMm, height: Self.cardH * pxPerMm)
                    Text("Приложите банковскую карту к рамке и подгоните кнопками - и + до совпадения. Масштаб запомнится.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                let fit = min((geo.size.width - 60) / trimW, (geo.size.height - 20) / trimH)
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if book && (page == 0 || page == last) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                                .frame(width: trimW / 2 * fit, height: trimH * fit)
                                .overlay(page == 0 ? Text("Альбом").font(.title.bold()) : nil)
                        } else if let spread {
                            SpreadPicture(store: store, spread: spread, format: f, scale: book ? fit : pxPerMm)
                        }
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
            }
            HStack {
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Button { page = min(last, page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= last).keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(8)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    private func scale(_ factor: Double) {
        pxPerMm = min(19, max(1.5, pxPerMm * factor))
        UserDefaults.standard.set(pxPerMm, forKey: Self.scaleKey)
    }
}

/// The spread as printed: bleed trimmed off, `scale` points per millimetre.
private struct SpreadPicture: View {
    let store: AppStore
    let spread: LayoutSpread
    let format: LayoutFormat
    let scale: Double

    var body: some View {
        let bleed = format.bleed_mm * scale
        let fullW = format.spread_w_mm * scale, fullH = format.spread_h_mm * scale
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(spread.cells, id: \.index) { cell in
                PrintCell(store: store, cell: cell)
                    .frame(width: cell.w * fullW, height: cell.h * fullH)
                    .offset(x: cell.x * fullW - bleed, y: cell.y * fullH - bleed)
            }
        }
        .frame(width: fullW - 2 * bleed, height: fullH - 2 * bleed, alignment: .topLeading).clipped()
        .shadow(radius: 4)
    }
}

private struct PrintCell: View {
    let store: AppStore
    let cell: LayoutCell
    @State private var image: CGImage?

    var body: some View {
        if let placement = cell.placement {
            CroppedPhoto(image: image, crop: placement.crop).clipped()
                .task(id: placement.image_id) {
                    let original = await store.original(imageId: placement.image_id)
                    image = original
                    if original == nil { image = await store.thumbnail(imageId: placement.image_id) }
                }
        } else {
            Color.clear
        }
    }
}
