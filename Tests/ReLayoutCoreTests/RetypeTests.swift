import XCTest
@testable import ReLayoutCore

// The hotkey's source of text (Core/Retype.swift).
final class RetypeTests: XCTestCase {

    func testASelectionWins() {
        XCTAssertEqual(retypeSource(selection: "ghbdtn", hasTypedWord: true, probeBlocked: false), .selection("ghbdtn"))
    }

    func testNothingSelectedMeansTheTypedWord() {
        XCTAssertEqual(retypeSource(selection: "", hasTypedWord: true, probeBlocked: false), .typedWord)
    }

    func testNothingSelectedAndNothingTypedAsksTheClipboard() {
        // VS Code reports no selection for a real one unless its accessibility support is on.
        XCTAssertEqual(retypeSource(selection: "", hasTypedWord: false, probeBlocked: false), .clipboardProbe)
    }

    func testNoAccessibilityTextAsksTheClipboardFirst() {
        XCTAssertEqual(retypeSource(selection: nil, hasTypedWord: true, probeBlocked: false), .clipboardProbe)
    }

    func testABlockedProbeFallsBackToTheTypedWord() {
        XCTAssertEqual(retypeSource(selection: nil, hasTypedWord: true, probeBlocked: true), .typedWord)
        XCTAssertEqual(retypeSource(selection: "", hasTypedWord: false, probeBlocked: true), .nothing)
    }

    func testAConsoleUsesOnlyTheTypedWord() {
        XCTAssertEqual(retypeSource(selection: "x", hasTypedWord: true, console: true, probeBlocked: false), .typedWord)
        XCTAssertEqual(retypeSource(selection: nil, hasTypedWord: false, console: true, probeBlocked: false), .nothing)
    }
}
