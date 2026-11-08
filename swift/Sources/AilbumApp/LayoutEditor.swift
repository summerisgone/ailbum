import AilbumCore
import SwiftUI

private let maxZoom = 4.0
private let zoomStep = 1.25

private struct EditorThumb: View {
    let store: AppStore
    let imageId: Int
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .task(id: imageId) { image = await store.thumbnail(imageId: imageId) }
    }
}

private func makeRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutRect {
    LayoutRect(x: x, y: y, w: w, h: h)
}

private func zoomOf(_ crop: LayoutRect) -> Double { 1 / max(0.0001, min(crop.w, crop.h)) }

private func zoomed(_ crop: LayoutRect, factor: Double) -> LayoutRect {
    let size = min(1.0, max(1 / maxZoom, min(crop.w, crop.h) / factor))
    let scale = size / min(crop.w, crop.h)
    let w = min(1.0, crop.w * scale), h = min(1.0, crop.h * scale)
    let cx = crop.x + crop.w / 2, cy = crop.y + crop.h / 2
    return makeRect(min(1 - w, max(0, cx - w / 2)), min(1 - h, max(0, cy - h / 2)), w, h)
}

struct LayoutEditor: View {
    let store: AppStore
    var onChange: (LayoutSpread) -> Void = { _ in }

    @State private var spread: LayoutSpread
    @State private var selected: Int?
    @State private var busy = false
    @State private var alternatives: [LayoutAlternative] = []
    @State private var similar: [LayoutAlternative] = []
    @State private var variants: [LayoutVariant] = []
    @State private var prompt = ""
    @State private var labels: [String] = []
    @State private var version = 0
    @State private var showSimilar = false
    @State private var message: String?
    @State private var dragStart: Int?

    let aspect: Double

    init(store: AppStore, spread: LayoutSpread, aspect: Double = 1.5, onChange: @escaping (LayoutSpread) -> Void = { _ in }) {
        self.store = store
        self.aspect = aspect
        self.onChange = onChange
        _spread = State(initialValue: spread)
    }

    private var cell: LayoutCell? { spread.cells.first { $0.index == selected } }
    private var placedId: Int? { cell?.placement?.image_id }
    private var spreadKey: String {
        "\(spread.template_id):" + spread.cells.map { $0.placement.map { String($0.image_id) } ?? "-" }.joined(separator: ",")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(spread.story_title).bold()
                    Text("Разворот \(spread.position)").foregroundStyle(.secondary)
                    ForEach(spread.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                Text("Колесо или щипок над выбранной ячейкой - масштаб, перетаскивание - кадрирование")
                    .font(.caption).foregroundStyle(.secondary)
                canvas
                if let reason = spread.assistant_reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                if let message { Text(message).foregroundStyle(.red).font(.caption) }
            }
            .frame(maxWidth: .infinity)
            panel.frame(width: 300)
        }
        .disabled(busy)
        .task(id: "\(selected ?? -1):\(placedId ?? -1):\(version)") { await loadCell() }
        .task(id: "\(spreadKey):\(version)") { await loadVariants() }
        .task(id: prompt) { await loadLabels() }
        .sheet(isPresented: $showSimilar) { similarSheet }
    }

    // MARK: canvas

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.08)
                ForEach(spread.cells, id: \.index) { c in
                    cellView(c, size: size)
                }
            }
            .coordinateSpace(name: "spread")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("spread"))
                    .onChanged { v in if dragStart == nil { dragStart = hit(v.startLocation, size) } }
                    .onEnded { v in
                        let from = dragStart
                        dragStart = nil
                        guard let from, let to = hit(v.location, size) else { return }
                        if from != to {
                            edit { try await store.layoutSwapCells(spreadId: spread.id, cellA: from, cellB: to) }
                        } else if let c = spread.cells.first(where: { $0.index == from }), let p = c.placement {
                            let dx = v.translation.width / (c.w * size.width) * p.crop.w
                            let dy = v.translation.height / (c.h * size.height) * p.crop.h
                            let crop = makeRect(
                                min(1 - p.crop.w, max(0, p.crop.x - dx)),
                                min(1 - p.crop.h, max(0, p.crop.y - dy)), p.crop.w, p.crop.h)
                            edit { try await store.layoutSetCrop(spreadId: spread.id, cellIndex: from, crop: crop) }
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("spread")).onEnded { t in
                    if let i = hit(t.location, size) { selected = selected == i ? nil : i }
                }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func hit(_ p: CGPoint, _ size: CGSize) -> Int? {
        spread.cells.first { c in
            p.x >= c.x * size.width && p.x <= (c.x + c.w) * size.width
                && p.y >= c.y * size.height && p.y <= (c.y + c.h) * size.height
        }?.index
    }

    private func cellView(_ c: LayoutCell, size: CGSize) -> some View {
        let w = c.w * size.width, h = c.h * size.height
        return ZStack {
            Color.gray.opacity(0.25)
            if let p = c.placement {
                let cw = max(0.0001, p.crop.w), ch = max(0.0001, p.crop.h)
                EditorThumb(store: store, imageId: p.image_id)
                    .frame(width: w / cw, height: h / ch)
                    .offset(x: -p.crop.x * w / cw + (w / cw - w) / 2 * 0, y: -p.crop.y * h / ch)
                    .frame(width: w, height: h, alignment: .topLeading)
                    .clipped()
            }
        }
        .frame(width: w, height: h)
        .clipped()
        .overlay(Rectangle().stroke(selected == c.index ? Color.accentColor : Color.white.opacity(0.6),
                                    lineWidth: selected == c.index ? 3 : 1))
        .position(x: c.x * size.width + w / 2, y: c.y * size.height + h / 2)
        .allowsHitTesting(false)
    }

    // MARK: panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if cell == nil {
                    Text("Выберите ячейку на развороте: здесь появятся варианты раскладки, масштаб и кандидаты на коллаж.")
                        .foregroundStyle(.secondary)
                } else {
                    variantsSection
                    cellSection
                    candidatesSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var variantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Разворот \(spread.position)").font(.headline)
            if !spread.story_title.isEmpty { Text(spread.story_title).font(.caption).foregroundStyle(.secondary) }
            Text("Варианты раскладки").font(.subheadline).bold()
            if variants.isEmpty {
                Text("Других вариантов нет").font(.caption).foregroundStyle(.secondary)
            } else {
                let count = spread.cells.count
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { _, v in
                        Button {
                            edit { try await store.layoutApplyVariant(spreadId: spread.id, templateId: v.template_id, imageIds: v.image_ids) }
                        } label: {
                            VStack {
                                variantThumb(v)
                                Text(v.image_ids.count == count ? "\(count) фото"
                                    : v.image_ids.count > count ? "\(v.image_ids.count) фото, +1 кадр"
                                    : "\(v.image_ids.count) фото, без 1 кадра").font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Заменить текущую раскладку разворота")
                    }
                }
            }
            Button("Пересобрать разворот") {
                edit { try await store.layoutRecompose(spreadId: spread.id, prompt: nil) }
            }
            Text("Пожелание сборщику").font(.subheadline).bold()
            TextField("Например: приоритет лицам и крупным планам", text: $prompt, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(labels.isEmpty ? "Не понято: укажите лица, крупные планы или пейзажи" : "Понято: \(labels.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(labels.isEmpty ? .orange : .secondary)
            }
            Button("Пересобрать с пожеланием") {
                let text = prompt
                edit { try await store.layoutRecompose(spreadId: spread.id, prompt: text) }
            }
            .disabled(labels.isEmpty)
        }
    }

    private func variantThumb(_ v: LayoutVariant) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.08)
                ForEach(v.cells, id: \.index) { c in
                    let w = c.w * geo.size.width, h = c.h * geo.size.height
                    let cw = max(0.0001, c.crop.w), ch = max(0.0001, c.crop.h)
                    EditorThumb(store: store, imageId: c.image_id)
                        .frame(width: w / cw, height: h / ch)
                        .offset(x: -c.crop.x * w / cw, y: -c.crop.y * h / ch)
                        .frame(width: w, height: h, alignment: .topLeading)
                        .clipped()
                        .offset(x: c.x * geo.size.width, y: c.y * geo.size.height)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    @ViewBuilder private var cellSection: some View {
        if let cell {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ячейка \(cell.index + 1)").font(.headline)
                if cell.placement?.replaced_image_id != nil { Text("Заменено похожим кадром").font(.caption) }
                if let p = cell.placement {
                    Button("Увеличить и выбрать из похожих" + (similar.count > 1 ? " (\(similar.count))" : "")) {
                        showSimilar = true
                    }
                    let z = zoomOf(p.crop)
                    HStack {
                        Text("Масштаб")
                        Button { zoom(cell, p, 1 / zoomStep) } label: { Image(systemName: "minus") }
                            .disabled(z <= 1.001).help("Уменьшить")
                        Text("x" + String(format: "%.1f", z)).bold()
                        Button { zoom(cell, p, zoomStep) } label: { Image(systemName: "plus") }
                            .disabled(z >= maxZoom - 0.01).help("Увеличить")
                        Button("Сбросить") { zoom(cell, p, 1 / maxZoom) }.disabled(z <= 1.001)
                    }
                }
            }
        }
    }

    private func zoom(_ c: LayoutCell, _ p: LayoutPlacement, _ factor: Double) {
        let crop = zoomed(p.crop, factor: factor)
        edit { try await store.layoutSetCrop(spreadId: spread.id, cellIndex: c.index, crop: crop) }
    }

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Кандидаты на коллаж").font(.headline)
            if let cell {
                Text("Кадры сюжета для ячейки \(cell.index + 1). Клик - поставить в ячейку.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(alternatives, id: \.image_id) { item in
                        VStack(spacing: 2) {
                            Button {
                                edit { try await store.layoutSetPhoto(spreadId: spread.id, cellIndex: cell.index, imageId: item.image_id) }
                            } label: {
                                EditorThumb(store: store, imageId: item.image_id)
                                    .frame(height: 60).clipped()
                                    .overlay(Rectangle().stroke(item.image_id == placedId ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .disabled(item.image_id == placedId)
                            .help(item.placed != nil ? "Поменять местами с этой ячейкой" : "Поставить в ячейку")
                            Text("\(Int((item.fit * 100).rounded()))%").font(.caption2)
                            if item.similar && item.image_id != placedId { Text("Похожий").font(.caption2).foregroundStyle(.blue) }
                            if !item.in_selection { Text("Не в отборе").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private var similarSheet: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Похожие кадры").font(.headline)
                Spacer()
                Button("Закрыть") { showSimilar = false }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 10) {
                    ForEach(similar, id: \.image_id) { item in
                        Button {
                            showSimilar = false
                            if let cell {
                                edit { try await store.layoutSetPhoto(spreadId: spread.id, cellIndex: cell.index, imageId: item.image_id) }
                            }
                        } label: {
                            EditorThumb(store: store, imageId: item.image_id).frame(height: 120).clipped()
                                .overlay(Rectangle().stroke(item.image_id == placedId ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .disabled(item.image_id == placedId)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 420)
    }

    // MARK: loading and editing

    private func edit(_ action: @escaping () async throws -> AilbumCore.Layout) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let layout = try await action()
                if let next = layout.spreads.first(where: { $0.id == spread.id }) {
                    spread = next
                    onChange(next)
                }
                message = nil
                version += 1
            } catch {
                message = AppStore.message(error)
            }
        }
    }

    private func loadCell() async {
        guard let index = selected else { alternatives = []; similar = []; return }
        do {
            let alt = try await store.layoutAlternatives(spreadId: spread.id, cellIndex: index)
            if !Task.isCancelled { alternatives = alt }
            if placedId == nil { similar = []; return }
            let sim = try await store.layoutSimilar(spreadId: spread.id, cellIndex: index)
            if !Task.isCancelled { similar = sim }
        } catch {
            if !Task.isCancelled { message = AppStore.message(error) }
        }
    }

    private func loadVariants() async {
        guard selected != nil else { variants = []; return }
        do {
            let items = try await store.layoutVariants(spreadId: spread.id)
            if !Task.isCancelled { variants = items }
        } catch {
            if !Task.isCancelled { message = AppStore.message(error) }
        }
    }

    private func loadLabels() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { labels = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        if let info = try? await store.layoutParsePrompt(text), !Task.isCancelled { labels = info.labels }
    }
}
