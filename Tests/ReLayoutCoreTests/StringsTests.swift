import XCTest
@testable import ReLayoutCore

final class StringsTests: XCTestCase {
    func testParsesPairsCommentsAndEscapes() {
        let table = parseStrings("""
        // a comment
        "menu.quit" = "Quit reLayout";
        /* block
           comment */
        "quote" = "say \\"hi\\"";   "two" = "a\\nb";
        """)
        XCTAssertEqual(table["menu.quit"], "Quit reLayout")
        XCTAssertEqual(table["quote"], "say \"hi\"")
        XCTAssertEqual(table["two"], "a\nb")
    }

    func testReadsCRLFFiles() {
        // A Windows checkout: a comment must end at "\r\n", not swallow the rest.
        let table = parseStrings("\"a\" = \"1\";\r\n// note\r\n\"b\" = \"2\";\r\n")
        XCTAssertEqual(table, ["a": "1", "b": "2"])
    }

    func testSkipsMalformedEntries() {
        let table = parseStrings("\"broken\" \"x\";\n\"ok\" = \"yes\";")
        XCTAssertEqual(table["ok"], "yes")
        XCTAssertNil(table["broken"])
    }

    func testEveryShippedTableHasTheEnglishKeys() throws {
        // Missing keys fall back to English on Windows but ship visibly broken UI
        // on macOS, so every language must carry every key.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let english = parseStrings(try String(contentsOf: root.appendingPathComponent("en.lproj/Localizable.strings"),
                                              encoding: .utf8))
        XCTAssertFalse(english.isEmpty)
        let langs = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".lproj") }
        for lang in langs {
            let table = parseStrings(try String(contentsOf: root.appendingPathComponent("\(lang)/Localizable.strings"),
                                                encoding: .utf8))
            let missing = Set(english.keys).subtracting(table.keys)
            XCTAssertTrue(missing.isEmpty, "\(lang) lacks \(missing.sorted())")
        }
    }

    func testTrigramModelReadsCRLFFiles() {
        // Same Windows-checkout trap for the shipped models: "\r\n" must split lines.
        let model = TrigramModel(text: "# model\r\nfloor -5.0\r\n^^a -1.0\r\n")
        XCTAssertEqual(model?.floor, -5.0)
        XCTAssertEqual(model?.score("a") ?? 0, (-1.0 + -5.0) / 2, accuracy: 0.001)   // "^^a" known, "^a$" not
    }
}
