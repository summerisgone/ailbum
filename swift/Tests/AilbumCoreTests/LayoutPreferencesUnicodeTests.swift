import Testing

@testable import AilbumCore

@Suite struct LayoutPreferencesUnicodeTests {
    @Test(arguments: [
        ("гор\u{301} и лица", ["faces": 1.0, "landscapes": 1.0]),
        ("вид\u{301}", ["landscapes": 1.0]),
        ("вид_", [:]),
        ("вид1 лица", ["faces": 1.0]),
        ("я\u{a0}не\u{a0}лиц", ["faces": -1.0]),
        ("не\u{2003}лиц", ["faces": -1.0]),
        (String(repeating: "😀", count: 498) + "лиц", [:]),
        (String(repeating: "😀", count: 250) + " лиц", ["faces": 1.0]),
        ("İ лиц", ["faces": 1.0]),
        ("не\u{301} лиц", ["faces": 1.0]),
        ("общий\u{301} план", [:]),
    ] as [(String, [String: Double])])
    func parseMatchesPythonUnicode(prompt: String, weights: [String: Double]) {
        #expect(Preferences.parse(prompt) == weights)
    }
}
