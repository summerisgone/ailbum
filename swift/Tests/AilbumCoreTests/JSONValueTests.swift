import XCTest
import Foundation
@testable import AilbumCore

final class JSONValueTests: XCTestCase {
    func testLiteralsAndSubscripts() {
        let v: JSONValue = ["a": 1, "b": [true, nil, "x", 1.5]]
        XCTAssertEqual(v["a"]?.intValue, 1)
        XCTAssertEqual(v["b"]?[0]?.boolValue, true)
        XCTAssertEqual(v["b"]?[1], JSONValue.null)
        XCTAssertEqual(v["b"]?[2]?.stringValue, "x")
        XCTAssertEqual(v["b"]?[3]?.doubleValue, 1.5)
        XCTAssertNil(v["b"]?[9])
        XCTAssertNil(v["zz"])
        XCTAssertEqual(v["a"]?.doubleValue, 1.0)
        XCTAssertNotNil(v.objectValue)
        XCTAssertNotNil(v["b"]?.arrayValue)
    }

    func testSQLValueConversion() {
        let row = JSONValue.row(["i": .integer(Int64(3)), "r": .real(0.5), "t": .text("s"),
                                 "n": .null, "b": .blob(Data([1]))])
        XCTAssertEqual(row, ["i": 3, "r": 0.5, "t": "s", "n": nil, "b": nil])
    }

    func testCodableRoundTrip() throws {
        let v: JSONValue = ["a": [1, 2.5, "x", nil, true], "o": ["k": "v"]]
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), v)
    }
}
