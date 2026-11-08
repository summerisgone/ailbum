import Foundation

public enum JobStatus: String, Sendable { case idle, running, complete, error, cancelled }

public struct JobState: Equatable, @unchecked Sendable {
    public var status: JobStatus
    public var kind: String?
    public var stage: String?
    public var detail: String
    public var current: Int?
    public var total: Int?
    public var error: String?
    public var result: JSONValue?

    public init(
        status: JobStatus = .idle, kind: String? = nil, stage: String? = nil, detail: String = "",
        current: Int? = nil, total: Int? = nil, error: String? = nil, result: JSONValue? = nil
    ) {
        self.status = status; self.kind = kind; self.stage = stage; self.detail = detail
        self.current = current; self.total = total; self.error = error; self.result = result
    }
}

/// Port of startDatabaseJob / database:job-cancel in desktop/electron/main.cjs.
public final class JobRunner: @unchecked Sendable {
    private let executable: URL
    private let lock = NSLock()
    private var state = JobState()
    private var active: Process?
    private let deliver = NSRecursiveLock()
    private var onUpdate: (@Sendable (JobState) -> Void)?

    public init(executable: URL) { self.executable = executable }

    public static func defaultExecutable() -> URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("ailbum-swift")
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }

    /// Updates from a process that is no longer `active` (cancelled) are dropped.
    /// `deliver` keeps callbacks in the same order as state changes.
    private func publish(from process: Process? = nil, _ change: (inout JobState) -> Void) {
        deliver.lock(); defer { deliver.unlock() }
        lock.lock()
        if let process, active !== process { lock.unlock(); return }
        change(&state)
        let snapshot = state
        let callback = onUpdate
        lock.unlock()
        callback?(snapshot)
    }

    public func start(
        kind: String, database: String, sources: [String], albumId: Int?, params: JSONValue?,
        onUpdate: @escaping @Sendable (JobState) -> Void
    ) throws {
        var args = [kind, "--database", database, "--models-dir", ModelStore.modelsDir.path]
        for s in sources { args += ["--source", URL(fileURLWithPath: s).standardizedFileURL.path] }
        if kind == "layout" {
            guard let albumId else { throw AilbumError.invalid("Не указан альбом для раскладки") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: try encoder.encode(params ?? .object([:])), as: UTF8.self)
            args += ["--album-id", String(albumId), "--params", json]
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err

        deliver.lock()
        lock.lock()
        if active != nil {
            lock.unlock(); deliver.unlock()
            throw AilbumError.invalid("Уже выполняется добавление или анализ фотографий")
        }
        active = process
        self.onUpdate = onUpdate
        lock.unlock()

        let stage = kind == "index" ? "Подготовка добавления" : kind == "layout" ? "Подготовка раскладки" : "Подготовка анализа"
        publish { $0 = JobState(status: .running, kind: kind, stage: stage, detail: "", result: $0.result) }
        deliver.unlock()

        do { try process.run() } catch {
            lock.lock(); if active === process { active = nil }; lock.unlock()
            publish(from: process) { $0.status = .error; $0.error = error.localizedDescription }
            return
        }

        let box = Box()
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread { [self] in
            var buffer = Data()
            let fh = out.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    handleLine(line: line, box: box, process: process)
                }
            }
            if !buffer.isEmpty { handleLine(line: String(decoding: buffer, as: UTF8.self), box: box, process: process) }
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            let fh = err.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                box.appendStderr(String(decoding: chunk, as: UTF8.self))
            }
            group.leave()
        }
        Thread.detachNewThread { [self] in
            process.waitUntilExit()
            group.wait()
            deliver.lock(); defer { deliver.unlock() }
            lock.lock()
            let owned = active === process
            if owned { active = nil }
            lock.unlock()
            if !owned { return }
            let code = process.terminationStatus
            if code != 0 {
                let fallback = box.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
                let message = [box.reportedError, fallback].compactMap { $0 }.first { !$0.isEmpty }
                    ?? "Фоновый процесс завершился с кодом \(code)"
                publish { $0.status = .error; $0.error = message }
            } else {
                publishFinalComplete(process)
            }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var error: String?
        private var tail = ""
        var reportedError: String? { get { lock.lock(); defer { lock.unlock() }; return error } set { lock.lock(); error = newValue; lock.unlock() } }
        var stderrTail: String { lock.lock(); defer { lock.unlock() }; return tail }
        func appendStderr(_ s: String) {
            lock.lock(); tail = String((tail + s).suffix(4000)); lock.unlock()
        }
    }

    private func publishFinalComplete(_ process: Process) {
        deliver.lock(); defer { deliver.unlock() }
        lock.lock(); let status = state.status; lock.unlock()
        if status != .complete { publish { $0.status = .complete; $0.current = nil; $0.total = nil } }
    }

    private func handleLine(line: String, box: Box, process: Process) {
        guard let parsed = try? JSONValue.parse(line) else {
            publish(from: process) { $0.status = .running; $0.detail = line }
            return
        }
        guard case .object(let o) = parsed else { return }
        switch o["type"]?.stringValue {
        case "progress":
            let detail = o["detail"]?.stringValue ?? ""
            publish(from: process) {
                $0.status = .running
                $0.stage = o["stage"]?.stringValue
                $0.detail = detail
                $0.current = o["current"]?.intValue
                $0.total = o["total"]?.intValue
            }
        case "error":
            box.reportedError = o["error"]?.stringValue
        case "complete":
            publish(from: process) { $0.status = .complete; $0.result = o["result"]; $0.current = nil; $0.total = nil }
        default: break
        }
    }

    public func cancel() {
        lock.lock()
        if let p = active {
            active = nil
            lock.unlock()
            p.terminate()
        } else { lock.unlock() }
        publish { $0.status = .cancelled; $0.stage = "Операция отменена"; $0.current = nil; $0.total = nil }
    }
}
