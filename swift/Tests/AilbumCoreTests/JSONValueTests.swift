import Testing
import Foundation
@testable import AilbumCore

@Suite struct JSONValueTests {
    @Test func literalsAndSubscripts() {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x", 1.5]]
        #expect(v["a"]?.intValue == 1)
        #expect(v["b"]?[0]?.boolValue == true)
        #expect(v["b"]?[1] == JSONValue.null)
        #expect(v["b"]?[2]?.stringValue == "x")
        #expect(v["b"]?[3]?.doubleValue == 1.5)
        #expect(v["b"]?[9] == nil)
        #expect(v["zz"] == nil)
        #expect(v["a"]?.doubleValue == 1.0)
        #expect(v.objectValue != nil)
        #expect(v["b"]?.arrayValue != nil)
    }

    @Test func sqlValueConversion() {
        let row = JSONValue.row(["i": .integer(Int64(3)), "r": .real(0.5), "t": .text("s"),
                                 "n": .null, "b": .blob(Data([1]))])
        #expect(row == ["i": 3, "r": 0.5, "t": "s", "n": nil, "b": nil])
    }

    @Test func codableRoundTrip() throws {
        let v: JSONValue = ["a": [1, 2.5, "x", nil, true], "o": ["k": "v"]]
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
    }
}
