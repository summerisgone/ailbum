import Foundation
import Testing
@testable import AilbumCore

private func tmpDir() throws -> String {
    let dir = NSTemporaryDirectory() + "ailbum-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Test func testAnnotationParserIgnoresVideo() throws {
    let path = try tmpDir() + "/stories.md"
    try "## Первая группа\na.jpg\nclip.mp4\nb.jpg\n\n## Вторая группа\nc.jpg\n"
        .write(toFile: path, atomically: true, encoding: .utf8)
    let parsed = try StoryEvaluation.parseAnnotations(path: path)
    #expect(parsed == [
        AnnotatedStory(title: "Первая группа", fileNames: ["a.jpg", "b.jpg"]),
        AnnotatedStory(title: "Вторая группа", fileNames: ["c.jpg"]),
    ])
}

@Test func testBalancedMetricsPenalizeMergingSmallGroups() {
    let expected = [
        AnnotatedStory(title: "Лобби отеля", fileNames: ["a.jpg", "b.jpg"]),
        AnnotatedStory(title: "Аквапарк", fileNames: ["c.jpg", "d.jpg"]),
    ]
    var predictions: [String: (Int, String)] = [:]
    for n in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"] { predictions[n] = (1, "Отдых в отеле") }
    let result = StoryEvaluation.evaluateGroups(expected: expected, predictions: predictions, runId: nil)
    #expect(result["macro_completeness"] == .double(1.0))
    #expect(result["bcubed_precision"] == .double(0.5))
    #expect(result["mixed_predicted_stories"] == .int(1))
}

@Test func testPerfectGroupingScoresOne() {
    let expected = [
        AnnotatedStory(title: "Лобби", fileNames: ["a.jpg", "b.jpg"]),
        AnnotatedStory(title: "Пляж", fileNames: ["c.jpg", "d.jpg"]),
    ]
    let predictions: [String: (Int, String)] = [
        "a.jpg": (1, "Лобби"), "b.jpg": (1, "Лобби"),
        "c.jpg": (2, "Пляж"), "d.jpg": (2, "Пляж"),
    ]
    let result = StoryEvaluation.evaluateGroups(expected: expected, predictions: predictions, runId: nil)
    #expect(result["pairwise_f1"] == .double(1.0))
    #expect(result["bcubed_f1"] == .double(1.0))
    #expect(result["mean_title_similarity"] == .double(1.0))
}

@Test func testTitleSimilarityMatchesDifflib() {
    let cases: [(String, String, Double)] = [
        ("Лобби отеля", "Отдых в отеле", 0.5),
        ("Аквапарк", "Аква-парк, день 2", 0.6666666666666666),
        ("Ужин в ресторане", "Ужин", 0.4),
        ("Ёлка и подарки", "Елка, подарки!", 0.8461538461538461),
        ("Прогулка по старому городу", "Вечерняя прогулка по городу", 0.6792452830188679),
        ("Яблоко бвг", String(repeating: "я", count: 250) + " бвг яблоко", 0.04428044280442804),
        ("Яблоко бвг", String(repeating: "я", count: 10) + " бвг яблоко", 0.3870967741935484),
        ("Море", String(repeating: "Поездка на море ", count: 20) + "Море", 0.0),
    ]
    for (a, b, want) in cases {
        #expect(abs(StoryEvaluation.titleSimilarity(a, b) - want) < 1e-12)
    }
}

@Test func testEmptyInputs() {
    let r = StoryEvaluation.evaluateGroups(expected: [], predictions: [:], runId: nil)
    #expect(r["run_id"] == .null)
    #expect(r["annotated_stories"] == .int(0))
    #expect(r["coverage"] == .double(0.0))
    #expect(r["minimum_completeness"] == .double(0.0))
    #expect(r["stories"] == .array([]))
}

@Test func testEvaluateDatabaseEmptyThrows() throws {
    let dir = try tmpDir()
    try "## A\na.jpg\n".write(toFile: dir + "/s.md", atomically: true, encoding: .utf8)
    #expect(throws: AilbumError.invalid("В базе нет запусков анализа")) {
        try StoryEvaluation.evaluateDatabase(database: dir + "/a.sqlite3", annotations: dir + "/s.md", runId: nil)
    }
}
