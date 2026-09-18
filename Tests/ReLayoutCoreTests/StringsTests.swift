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
}
