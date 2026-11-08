import Foundation
import Testing
@testable import AilbumCore

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [JobState] = []
    func add(_ s: JobState) { lock.lock(); items.append(s); lock.unlock() }
    var all: [JobState] { lock.lock(); defer { lock.unlock() }; return items }
    var last: JobState? { all.last }
    func wait(timeout: Double = 10, _ cond: (JobState) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let l = last, cond(l) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}

private func script(_ body: String) throws -> URL {
    let dir = NSTemporaryDirectory() + "jobrunner-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: dir + "/job.sh")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func isDone(_ s: JobState) -> Bool { s.status == .complete || s.status == .error || s.status == .cancelled }

@Suite struct JobRunnerTests {
    @Test func initialStageLabels() throws {
        for (kind, label) in [("index", "Подготовка добавления"), ("layout", "Подготовка раскладки"), ("analyze", "Подготовка анализа")] {
            let c = Collector()
            let r = JobRunner(executable: try script("sleep 5"))
            try r.start(kind: kind, database: "/d.db", sources: [], albumId: 1, params: .object([:]), onUpdate: c.add)
            #expect(c.all.first == JobState(status: .running, kind: kind, stage: label, detail: ""))
            r.cancel()
        }
    }

    @Test func argumentsAndProgressAndComplete() throws {
        let out = NSTemporaryDirectory() + "args-\(UUID().uuidString)"
        let exe = try script("""
        for a in "$@"; do printf '%s\\n' "$a" >> \(out); done
        echo '{"type":"progress","stage":"Анализ","current":3,"total":10,"detail":"a.jpg"}'
        echo 'plain line'
        echo '{"type":"complete","result":{"run_id":"r1"}}'
        """)
        let c = Collector()
        let r = JobRunner(executable: exe)
        try r.start(kind: "layout", database: "/tmp/x.db", sources: ["/a/b/../c"], albumId: 7, params: ["k": .int(1)], onUpdate: c.add)
        #expect(c.wait { $0.status == .complete })
        #expect(c.all.contains { $0.stage == "Анализ" && $0.current == 3 && $0.total == 10 && $0.detail == "a.jpg" })
        #expect(c.all.contains { $0.status == .running && $0.detail == "plain line" })
        #expect(c.last?.result == .object(["run_id": .string("r1")]))
        #expect(c.last?.current == nil && c.last?.total == nil)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(c.last?.status == .complete)
        let args = try String(contentsOfFile: out, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["job", "layout", "--database", "/tmp/x.db", "--models-dir", ModelStore.modelsDir.path,
                         "--source", "/a/c", "--album-id", "7", "--params", "{\"k\":1}"])
    }

    @Test func reportedErrorWinsOverStderr() throws {
        let c = Collector()
        let r = JobRunner(executable: try script("echo '{\"type\":\"error\",\"error\":\"Нет фото\"}'\necho boom >&2\nexit 2"))
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        #expect(c.wait(isDone))
        #expect(c.last?.status == .error && c.last?.error == "Нет фото")
    }

    @Test func stderrTailFallback() throws {
        let c = Collector()
        let r = JobRunner(executable: try script("printf 'first\\nlast line\\n' >&2\nexit 3"))
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        #expect(c.wait(isDone))
        #expect(c.last?.error == "last line")
    }

    @Test func exitCodeMessage() throws {
        let c = Collector()
        let r = JobRunner(executable: try script("exit 5"))
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        #expect(c.wait(isDone))
        #expect(c.last?.status == .error && c.last?.error == "Фоновый процесс завершился с кодом 5")
    }

    @Test func cleanExitWithoutCompleteEventCompletes() throws {
        let c = Collector()
        let r = JobRunner(executable: try script("exit 0"))
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        #expect(c.wait { $0.status == .complete })
    }

    @Test func secondStartWhileRunningThrows() throws {
        let r = JobRunner(executable: try script("sleep 5"))
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: { _ in })
        #expect(r.isRunning)
        #expect {
            try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: { _ in })
        } throws: { "\($0)".contains("Уже выполняется добавление или анализ фотографий") || $0.localizedDescription.contains("Уже выполняется") }
        r.cancel()
    }

    @Test func cancelSuppressesExitUpdate() throws {
        let c = Collector()
        let r = JobRunner(executable: try script("sleep 30"))
        try r.start(kind: "analyze", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        r.cancel()
        #expect(c.last?.status == .cancelled && c.last?.stage == "Операция отменена")
        let n = c.all.count
        Thread.sleep(forTimeInterval: 0.6)
        #expect(c.all.count == n)
        #expect(!r.isRunning)
        let c2 = Collector()
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c2.add)
        r.cancel()
    }
}

@Suite struct JobRunnerRaceTests {
    @Test func cancelThenImmediateRestartIsNotPoisonedByOldExit() throws {
        let r = JobRunner(executable: try script("sleep 30"))
        let c = Collector()
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: { _ in })
        r.cancel()
        try r.start(kind: "analyze", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        Thread.sleep(forTimeInterval: 0.8)
        #expect(c.all.allSatisfy { $0.status == .running })
        #expect(r.isRunning)
        r.cancel()
    }

    @Test func chattyChildDoesNotBlock() throws {
        let c = Collector()
        let r = JobRunner(executable: try script("i=0; while [ $i -lt 3000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done\necho '{\"type\":\"complete\",\"result\":{}}'"))
        try r.start(kind: "index", database: "d", sources: [], albumId: nil, params: nil, onUpdate: c.add)
        #expect(c.wait { $0.status == .complete })
    }
}
