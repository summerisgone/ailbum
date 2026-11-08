import AilbumCore
import SwiftUI

private func peopleLabel(_ person: PersonSummary) -> String {
    person.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Человек \(person.id)"
}

private func faceDate(_ value: String?) -> String {
    guard let value else { return "Дата неизвестна" }
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: value) ?? plain.date(from: value) else { return "Дата неизвестна" }
    return date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "ru")))
}

struct PeopleSection: View {
    let store: AppStore

    @State private var started = false
    @State private var activeId: Int?
    @State private var collection: FaceCollection?
    @State private var nameDraft = ""
    @State private var loadingFaces = false
    @State private var pendingFaces: Set<Int> = []
    @State private var savingName = false
    @State private var mergeTarget: PersonSummary?
    @State private var merging = false
    @FocusState private var nameFocused: Bool

    init(store: AppStore) { self.store = store }

    private var people: [PersonSummary] { store.people?.people ?? [] }

    private var activePerson: FacePerson? {
        guard let person = collection?.person, person.id == activeId else { return nil }
        return person
    }

    private var mergeCandidates: [PersonSummary] {
        guard let active = activePerson else { return [] }
        return people.filter { $0.id != active.id && $0.embedding_model == active.embedding_model }
    }

    private var normalizedDraft: String { nameDraft.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "ru")) }

    private var draftMatchesTarget: Bool {
        mergeTarget?.name?.lowercased(with: Locale(identifier: "ru")) == normalizedDraft
    }

    var body: some View {
        Group {
            if store.people == nil || !started {
                loading
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 260)
                    Divider()
                    workspace
                }
            }
        }
        .task {
            await store.getPeople()
            if let first = store.people?.people.first?.id { activeId = first }
            started = true
            await loadFaces(activeId)
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Загружаем лица…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Люди").foregroundStyle(.secondary)
                Spacer()
                Text("\(people.count)").bold()
            }
            .padding(12)
            ScrollView {
                VStack(spacing: 2) {
                    row(selected: activeId == nil, avatar: "person.2", title: "Без человека",
                        subtitle: "Нужно разобрать", count: store.people?.unassigned_count ?? 0) { select(nil) }
                    ForEach(people, id: \.id) { person in
                        row(selected: activeId == person.id,
                            avatar: String((person.name?.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "?").uppercased()),
                            title: peopleLabel(person), subtitle: "\(person.photo_count) фото",
                            count: person.face_count) { select(person.id) }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func row(selected: Bool, avatar: String, title: String, subtitle: String, count: Int,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(.quaternary)
                    if avatar == "person.2" { Image(systemName: avatar) } else { Text(avatar).bold() }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).bold().lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(count)").bold()
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: Workspace

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let active = activePerson, let target = mergeTarget { mergeConfirm(active: active, target: target) }
            if loadingFaces || collection == nil {
                loading
            } else if collection?.faces.isEmpty ?? true {
                VStack(spacing: 6) {
                    Image(systemName: "person.2").font(.largeTitle)
                    Text(activeId == nil ? "Все лица распределены" : "У человека пока нет лиц").font(.headline)
                    Text("Назначение можно изменить в меню на карточке любого лица.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(collection?.faces ?? [], id: \.id) { face in
                            FaceCard(store: store, face: face, people: people, pending: pendingFaces.contains(face.id)) {
                                destination in Task { await assign(face, destination) }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeId == nil ? "Не назначены" : "Выбранный человек")
                    .font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
                if activeId == nil {
                    Text("Лица без связи").font(.title2).bold()
                } else {
                    HStack {
                        TextField("Человек \(activeId ?? 0)", text: $nameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2)
                            .frame(maxWidth: 320)
                            .focused($nameFocused)
                            .help("Имя применяется ко всем фото этого человека")
                            .accessibilityLabel("Имя человека")
                            .onChange(of: nameDraft) { mergeTarget = nil }
                            .onSubmit { Task { await saveName() } }
                            .onChange(of: nameFocused) { _, focused in if !focused { Task { await saveName() } } }
                        if savingName { ProgressView().controlSize(.small) } else { Image(systemName: "pencil") }
                    }
                }
            }
            Spacer()
            if !mergeCandidates.isEmpty {
                Picker("Объединить с другим человеком", selection: Binding<Int>(
                    get: { 0 },
                    set: { id in mergeTarget = mergeCandidates.first { $0.id == id } }
                )) {
                    Text("Это тот же человек, что…").tag(0)
                    ForEach(mergeCandidates, id: \.id) { person in
                        Text("\(peopleLabel(person)) · \(person.photo_count) фото").tag(person.id)
                    }
                }
                .labelsHidden()
                .disabled(merging)
                .frame(maxWidth: 260)
            }
            VStack(alignment: .trailing) {
                Text("\(collection?.faces.count ?? 0)").font(.title3).bold()
                Text("наблюдений лица").font(.caption).foregroundStyle(.secondary)
                if let person = collection?.person {
                    Text(person.embedding_model).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func mergeConfirm(active: FacePerson, target: PersonSummary) -> some View {
        HStack {
            Text("\(active.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Человек \(active.id)") и \(peopleLabel(target)) - один человек? Все лица перейдут к одной записи для всех фото. Отменить объединение можно только вручную.")
            Spacer()
            Button {
                Task { await mergeActive() }
            } label: {
                if merging { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.triangle.merge") }
                Text("Объединить")
            }
            .buttonStyle(.borderedProminent)
            .disabled(merging)
            Button(draftMatchesTarget ? "Это другой человек" : "Отмена") { dismissMerge() }
                .disabled(merging || savingName)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Объединение людей")
    }

    // MARK: Actions

    private func select(_ id: Int?) {
        guard id != activeId || collection == nil else { return }
        activeId = id
        mergeTarget = nil
        collection = nil
        Task { await loadFaces(id) }
    }

    private func loadFaces(_ id: Int?) async {
        loadingFaces = true
        defer { loadingFaces = false }
        do {
            let next = try await store.getFaces(personId: id)
            guard id == activeId else { return }
            collection = next
            nameDraft = next.person?.name ?? ""
        } catch {
            store.error = AppStore.message(error)
        }
    }

    private func commitName() async {
        guard let active = activePerson, !savingName else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespaces)
        savingName = true
        mergeTarget = nil
        await store.setPersonName(active.id, name: name)
        await store.getPeople()
        if collection?.person?.id == active.id { collection?.person?.name = name.isEmpty ? nil : name }
        savingName = false
    }

    private func saveName() async {
        guard let active = activePerson,
              nameDraft.trimmingCharacters(in: .whitespaces) != (active.name ?? "") else { return }
        // The typed name already belongs to someone: this is most likely the same person.
        if !normalizedDraft.isEmpty,
           let same = mergeCandidates.first(where: { $0.name?.lowercased(with: Locale(identifier: "ru")) == normalizedDraft }) {
            mergeTarget = same
            return
        }
        await commitName()
    }

    private func dismissMerge() {
        if draftMatchesTarget { Task { await commitName() }; return }
        nameDraft = activePerson?.name ?? ""
        mergeTarget = nil
    }

    private func mergeActive() async {
        guard let active = activePerson, let target = mergeTarget, !merging else { return }
        merging = true
        store.error = nil
        await store.mergePerson(source: active.id, target: target.id)
        await store.getPeople()
        merging = false
        guard store.error == nil else { return }
        mergeTarget = nil
        select(target.id)
    }

    private func assign(_ face: Face, _ destination: FaceDestination) async {
        guard !pendingFaces.contains(face.id) else { return }
        pendingFaces.insert(face.id)
        defer { pendingFaces.remove(face.id) }
        switch destination {
        case .new:
            if let id = await store.createPersonFromFace(face.id, name: "") {
                await store.getPeople()
                select(id)
            }
        case .none, .person:
            var personId: Int?
            if case .person(let id) = destination { personId = id }
            await store.assignFace(face.id, personId: personId)
            await store.getPeople()
            await loadFaces(activeId)
        }
    }
}

private enum FaceDestination: Hashable {
    case none, new, person(Int)
}

private struct FaceCard: View {
    let store: AppStore
    let face: Face
    let people: [PersonSummary]
    let pending: Bool
    let onAssign: (FaceDestination) -> Void

    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                    }
                    .clipped()
                if pending {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.3))
                }
                Text("\(Int((face.confidence * 100).rounded()))%")
                    .font(.caption2).bold().padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(face.file_name).bold().lineLimit(1).help(face.file_name)
            Text(faceDate(face.taken_at)).font(.caption).foregroundStyle(.secondary)
            Picker("Назначение лица из \(face.file_name)", selection: Binding<FaceDestination>(
                get: { face.person_id.map { .person($0) } ?? .none },
                set: { onAssign($0) }
            )) {
                Text("Без человека").tag(FaceDestination.none)
                Text("＋ Новый человек").tag(FaceDestination.new)
                ForEach(people.filter { $0.embedding_model == face.embedding_model }, id: \.id) { person in
                    Text("\(peopleLabel(person)) · \(person.face_count)").tag(FaceDestination.person(person.id))
                }
            }
            .labelsHidden()
            .disabled(pending)
        }
        .task(id: face.id) { image = await store.faceThumbnail(faceId: face.id) }
    }
}
