import AppKit
import AilbumCore
import SwiftUI
import UniformTypeIdentifiers

struct DatabaseSection: View {
    let store: AppStore
    @State private var summary: DatabaseSummary?
    @State private var folders: [String] = []
    @State private var dragging = false
    @State private var summaryError: String?

    init(store: AppStore) { self.store = store }

    private var job: JobState { store.job }
    private var running: Bool { job.status == .running }
    private var library: Library? { store.library }
    private var hasAnalysis: Bool { library?.run != nil || library?.album != nil }

    private var progress: Double? {
        guard let c = job.current, let t = job.total, t > 0 else { return nil }
        return min(1, Double(c) / Double(t))
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack { Text("\(value)").font(.title2).bold(); Text(label).font(.footnote).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }

    private func refreshSummary() async {
        do { summary = try await store.getDatabaseSummary() } catch { switch error {
            case AilbumError.invalid(let m), AilbumError.sqlite(let m), AilbumError.decode(let m), AilbumError.metal(let m): store.error = m
            default: store.error = error.localizedDescription
            } }
    }

    private func addFolders(_ paths: [String]) {
        for p in paths where !p.isEmpty && !folders.contains(p) { folders.append(p) }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папки с фотографиями"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addFolders(panel.urls.map(\.path)) }
    }

    private func switchDatabase(create: Bool) {
        let path: String?
        if create {
            let panel = NSSavePanel()
            panel.title = "Создать базу Ailbum"
            panel.nameFieldStringValue = "ailbum.sqlite3"
            path = panel.runModal() == .OK ? panel.url?.path : nil
        } else {
            let panel = NSOpenPanel()
            panel.title = "Выберите каталог Ailbum"
            panel.allowedContentTypes = ["sqlite3", "sqlite", "db"].compactMap { UTType(filenameExtension: $0) }
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            path = panel.runModal() == .OK ? panel.url?.path : nil
        }
        guard let path else { return }
        folders = []
        Task {
            if create { await store.createDatabase(path: path) } else { await store.openDatabase(path: path) }
            await refreshSummary()
        }
    }

    private func start(_ kind: String, _ sources: [String]) {
        Task { await store.startDatabaseJob(kind: kind, sources: sources) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("База данных и анализ").font(.title2).bold()
                current
                addSection
                analysisSection
                if job.status != .idle { jobPanel }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.database) { await refreshSummary() }
        .onChange(of: job.status) { _, status in if status == .complete { Task { await refreshSummary() } } }
    }

    private var current: some View {
        let database = library?.database ?? store.database ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            Text(URL(fileURLWithPath: database).lastPathComponent).bold()
            Text(database).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(database)
            HStack {
                stat(summary?.available ?? library?.photos.count ?? 0, "фото")
                stat(summary?.analysis_runs ?? ((library?.run != nil || library?.album != nil) ? 1 : 0), "анализов")
                stat(summary?.people ?? 0, "людей")
                stat(summary?.stories ?? library?.stories.count ?? 0, "сюжетов")
            }
            HStack {
                Button("Открыть другую") { switchDatabase(create: false) }.disabled(running)
                Button("Создать новую") { switchDatabase(create: true) }.disabled(running)
            }
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Добавить фотографии").bold()
            Text("Перетащите одну или несколько папок. В базу попадут фотографии из всех вложенных каталогов.")
                .font(.footnote).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text(dragging ? "Отпустите папки здесь" : "Перетащите папки с фото").bold()
                Text("или")
                Button("Выбрать папки", action: chooseFolders).disabled(running)
            }
            .frame(maxWidth: .infinity).padding()
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(dragging ? Color.accentColor : Color.secondary))
            .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                        Task { @MainActor in addFolders([url.path]) }
                    }
                }
                return true
            }
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder")
                    Text(folder).lineLimit(1).truncationMode(.middle).help(folder)
                    Spacer()
                    Button { folders.removeAll { $0 == folder } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).disabled(running).help("Убрать папку")
                }
            }
            Button {
                start("index", folders)
            } label: {
                if running && job.kind == "index" { ProgressView().controlSize(.small) } else { Image(systemName: "plus") }
                Text("Добавить в базу")
            }
            .disabled(running || folders.isEmpty)
        }
    }

    private var analysisSection: some View {
        let single = folders.count == 1
        let title = single ? "Анализ выбранной папки" : hasAnalysis ? "Повторный анализ" : "Анализ фотографий"
        let source: String = single ? "Источник: \(folders[0])"
            : library?.run != nil ? "Последний источник: \(library!.run!.source)"
            : library?.album?.sources.first.map { "Источник: \($0)" } ?? "Выберите одну папку выше, чтобы запустить первый анализ."
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).bold()
            Text(source).font(.footnote).foregroundStyle(.secondary)
            Button {
                start("analyze", single ? folders : [])
            } label: {
                if running && job.kind == "analyze" { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                Text(single || !hasAnalysis ? "Запустить анализ папки" : "Запустить анализ заново")
            }
            .disabled(running || (!hasAnalysis && !single))
        }
    }

    private var jobPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if running { ProgressView().controlSize(.small) }
                else { Image(systemName: job.status == .complete ? "checkmark" : "xmark") }
                VStack(alignment: .leading) {
                    Text(job.stage ?? (job.status == .complete ? "Готово" : "Операция остановлена")).bold()
                    if !job.detail.isEmpty { Text(job.detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if running { Button("Отменить") { Task { await store.cancelDatabaseJob() } } }
            }
            if running {
                if let progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
                if let c = job.current, let t = job.total { Text("\(c) из \(t) фотографий") }
            }
            if job.status == .error, let e = job.error { Text(e) }
            if job.status == .complete { Text("Данные обновлены, каталог перезагружен.") }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
