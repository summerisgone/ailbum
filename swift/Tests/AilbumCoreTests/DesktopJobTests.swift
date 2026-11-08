import Foundation
import Testing
@testable import AilbumCore

private let fakesWanted = ProcessInfo.processInfo.environment["SUPERLITE_REAL"] != "1"

private final class Recorder: @unchecked Sendable {
    var events: [JSONValue] = []
    var generateArgs: (Int, LayoutParams, String?)?
    var analyzeArgs: (String, String, PipelineConfig, String)?
}

/// Installs the fake seams by default; SUPERLITE_REAL=1 leaves the real implementations.
private func withFakes(_ rec: Recorder, _ body: () throws -> Void) rethrows {
    if fakesWanted {
        DesktopJob.generateOverride = { _, albumId, params, models, progress in
            rec.generateArgs = (albumId, params, models)
            progress?("Компоновка", "x", 1, 2)
            return ["id": 3]
        }
        DesktopJob.analyzeOverride = { source, output, config, _, database in
            rec.analyzeArgs = (source, output, config, database)
            return ["run_id": "r9", "summary": ["n": 1]]
        }
    }
    defer {
        DesktopJob.generateOverride = nil
        DesktopJob.analyzeOverride = nil
        DesktopJob.indexOverride = nil
    }
    try body()
}

private func tempDir() throws -> String {
    let dir = Catalog.resolve(NSTemporaryDirectory()) + "/ailbum-job-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Suite(.serialized)
struct DesktopJobTests {
    @Test func jobParserAcceptsLayoutKind() {
        let rec = Recorder()
        withFakes(rec) {
            let code = DesktopJob.run(
                ["layout", "--database", "a.db", "--album-id", "1", "--params", "{\"orientation\":\"vertical\",\"spread_count\":1,\"min_photos\":1,\"max_photos\":2}"],
                emit: { rec.events.append($0) })
            if fakesWanted {
                #expect(code == 0)
                #expect(rec.generateArgs?.0 == 1)
            }
        }
        #expect(DesktopJob.run(["bogus", "--database", "a.db"], emit: { rec.events.append($0) }) == 2)
        #expect(DesktopJob.run(["layout"], emit: { rec.events.append($0) }) == 2)
        #expect(rec.events.last?["type"] == "error")
    }

    @Test func invalidParamsJsonEmitsErrorEvent() {
        var events: [JSONValue] = []
        let code = DesktopJob.run(
            ["layout", "--database", "a.db", "--album-id", "1", "--params", "{bad"], emit: { events.append($0) })
        #expect(code == 2)
        #expect(events.last?["type"] == "error")
        #expect(events.last?["error"]?.stringValue?.hasPrefix("JSONDecodeError: ") == true)
        events = []
        #expect(DesktopJob.run(["layout", "--database", "a.db", "--album-id", "1", "--params", "[]"], emit: { events.append($0) }) == 2)
        #expect(events.last?["error"] == "TypeError: Параметры раскладки должны быть JSON-объектом")
        events = []
        #expect(DesktopJob.run(["layout", "--database", "a.db"], emit: { events.append($0) }) == 2)
        #expect(events.last?["error"] == "ValueError: Не указаны альбом и параметры раскладки")
    }

    @Test func layoutJobRunsGenerateAndReportsProgress() {
        guard fakesWanted else { return }
        let rec = Recorder()
        withFakes(rec) {
            let code = DesktopJob.run(
                ["layout", "--database", "a.db", "--album-id", "1", "--models-dir", "m", "--params",
                 "{\"orientation\":\"vertical\",\"spread_count\":4,\"min_photos\":3,\"max_photos\":5,\"assistant\":\"off\"}"],
                emit: { rec.events.append($0) })
            #expect(code == 0)
        }
        #expect(rec.events[0] == ["type": "progress", "stage": "Компоновка", "detail": "x", "current": 1, "total": 2])
        #expect(rec.events.last == ["type": "complete", "result": ["id": 3]])
        #expect(rec.generateArgs?.0 == 1)
        #expect(rec.generateArgs?.1 == LayoutParams(orientation: "vertical", spreadCount: 4, minPhotos: 3, maxPhotos: 5, assistant: "off"))
        #expect(rec.generateArgs?.2 == "m")
    }

    @Test func exportOriginalsCopiesInAlbumOrder() throws {
        let dir = try tempDir()
        let photos = dir + "/src"
        try FileManager.default.createDirectory(atPath: photos, withIntermediateDirectories: true)
        let dbPath = dir + "/a.db"
        let db = try Database.open(path: dbPath)
        try db.execute("INSERT INTO analysis_runs VALUES ('r','s','o','t','t','b','{}','{}','completed')", [])
        for i in 1...3 {
            if i != 3 { try Data(repeating: 120, count: i).write(to: URL(fileURLWithPath: photos + "/p\(i).jpg")) }
            try db.execute(
                "INSERT INTO images (id, path, source_root, relative_path, file_name, extension,"
                + " file_size_bytes, modified_at, sha256, exif_json, container_metadata_json, indexed_at)"
                + " VALUES (?, ?, 's', ?, ?, 'jpg', 1, 't', 'x', '{}', '{}', 't')",
                [.integer(i), .text(photos + "/p\(i).jpg"), .text("p\(i)"), .text("p\(i).jpg")])
        }
        try db.execute("INSERT INTO albums (id, public_id, title, run_id, created_at, updated_at) VALUES (1, 'u1', 'А', 'r', 't', 't')", [])
        try db.execute(
            "INSERT INTO layouts (id, album_id, run_id, orientation, spread_count, min_photos, max_photos, selection_hash, created_at, updated_at)"
            + " VALUES (1,1,'r','vertical',2,1,2,'h','t','t')", [])
        try db.execute("INSERT INTO layout_spreads VALUES (5, 1, 2, 'full', '[]', '[]', NULL)", [])
        try db.execute("INSERT INTO layout_spreads VALUES (6, 1, 1, 'pages', '[]', '[]', NULL)", [])
        for (spread, cell, image) in [(5, 0, 1), (6, 0, 2), (6, 1, 3)] {
            try db.execute("INSERT INTO layout_placements VALUES (?, ?, ?, 0, 0, 1, 1, 1, '[]', NULL)",
                           [.integer(spread), .integer(cell), .integer(image)])
        }
        let out = dir + "/out"
        let result = try LayoutExport.exportOriginals(database: dbPath, albumId: 1, folder: out)
        #expect(result["count"]?.intValue == 2)
        #expect(result["missing"] == [.string(photos + "/p3.jpg")])
        let names = try FileManager.default.contentsOfDirectory(atPath: out + "/" + LayoutExport.exportDir).sorted()
        #expect(names == ["01-1_p2.jpg", "02-1_p1.jpg"])
        let again = try LayoutExport.exportOriginals(database: dbPath, albumId: 1, folder: out)
        #expect(again["folder"]?.stringValue == out + "/" + LayoutExport.exportDir + " 2")
    }

    @Test func analysisJobAttachesRun() throws {
        guard fakesWanted else { return }
        let dir = try tempDir()
        let source = dir + "/ph"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        let dbPath = dir + "/a.db"
        let db = try Database.open(path: dbPath)
        try db.execute("INSERT INTO analysis_runs VALUES ('r9','s','o','t','t','b','{}','{}','completed')", [])
        let rec = Recorder()
        try withFakes(rec) {
            let result = try DesktopJob.runAnalysis(dbPath, source: source, output: dir + "/o", modelsDir: nil, emit: { rec.events.append($0) })
            #expect(result == ["run_id": "r9", "album_id": 1, "summary": ["n": 1]])
        }
        let rows = try db.query("SELECT source_root FROM album_sources WHERE album_id = 1", [])
        #expect(rows.first?["source_root"] == .text(source))
    }

    @Test func analysisReusesLatestRunSourceOutputAndConfig() throws {
        guard fakesWanted else { return }
        let dir = try tempDir()
        let dbPath = dir + "/a.db"
        let db = try Database.open(path: dbPath)
        try db.execute("INSERT INTO analysis_runs VALUES ('old','/s1','/o1','t','2020','b','{}','{}','completed')", [])
        try db.execute(
            "INSERT INTO analysis_runs VALUES ('r9','/s2','/o2','t','2021','b','{\"photo_hash_distance\":7,\"bogus\":1,\"models_dir\":\"/mm\"}','{}','completed')", [])
        let rec = Recorder()
        try withFakes(rec) {
            _ = try DesktopJob.runAnalysis(dbPath, source: nil, output: nil, modelsDir: nil, emit: { _ in })
        }
        #expect(rec.analyzeArgs?.0 == "/s2")
        #expect(rec.analyzeArgs?.1 == "/o2")
        #expect(rec.analyzeArgs?.2.photoHashDistance == 7)
        #expect(rec.analyzeArgs?.2.modelsDir.path == "/mm")
        var events: [JSONValue] = []
        let empty = dir + "/none.db"
        #expect(DesktopJob.run(["analyze", "--database", empty], emit: { events.append($0) }) == 2)
        #expect(events.last?["error"] == "ValueError: Сначала перетащите папку с фотографиями")
        events = []
        #expect(DesktopJob.run(["analyze", "--database", empty, "--source", "a", "--source", "b"], emit: { events.append($0) }) == 2)
        #expect(events.last?["error"] == "ValueError: Одновременно можно анализировать только одну папку")
        events = []
        #expect(DesktopJob.run(["index", "--database", empty], emit: { events.append($0) }) == 2)
        #expect(events.last?["error"] == "ValueError: Не выбраны папки с фотографиями")
    }

    @Test func progressEventShapes() {
        #expect(DesktopJob.progressEvent("[3/10] a.jpg", defaultStage: "Анализ фотографий")
            == ["type": "progress", "stage": "Анализ фотографий", "current": 3, "total": 10, "detail": "a.jpg"])
        #expect(DesktopJob.progressEvent("Этап: Лица | 5", defaultStage: "x")
            == ["type": "progress", "stage": "Лица", "detail": "5"])
        #expect(DesktopJob.progressEvent("что-то", defaultStage: "x")
            == ["type": "progress", "stage": "Обработка", "detail": "что-то"])
    }

    @Test func indexJobReportsProgressPerFolder() throws {
        let dir = try tempDir()
        let rec = Recorder()
        DesktopJob.indexOverride = { _, _, progress in
            progress?(2, 5)
            return ["indexed": 5]
        }
        defer { DesktopJob.indexOverride = nil }
        let code = DesktopJob.run(["index", "--database", dir + "/a.db", "--source", dir], emit: { rec.events.append($0) })
        #expect(code == 0)
        #expect(rec.events[0]["detail"] == .string("Папка 1 из 1: " + (dir as NSString).lastPathComponent))
        #expect(rec.events[1] == ["type": "progress", "stage": "Добавление фотографий", "current": 2, "total": 5, "detail": ""])
        #expect(rec.events.last == ["type": "complete", "result": ["sources": [["indexed": 5, "source": .string(dir)]]]])
    }

    @Test func layoutParamsCutsPromptAndDefaults() throws {
        let long = String(repeating: "я", count: 600)
        let p = try DesktopJob.layoutParams("{\"orientation\":\"h\",\"spread_count\":\"2\",\"min_photos\":1,\"max_photos\":3.9,\"prompt\":\"\(long)\"}")
        #expect(p.assistant == "auto" && p.maxPhotos == 3 && p.spreadCount == 2)
        #expect(p.prompt.unicodeScalars.count == 500)
    }
}
