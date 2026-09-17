import RelayoutUIA
import ReLayoutCore

// Swift side of the UI Automation read (windows/uia): the selection, read without
// touching it or the clipboard, like the macOS AX path.

/// The focused control's selected text.
/// - Returns: nil when the control exposes no UI Automation text (the caller falls
///   back to the clipboard); "" when nothing is selected.
func readSelectedText() -> String? {
    var buf = [UInt16](repeating: 0, count: 4096)
    let n = buf.withUnsafeMutableBufferPointer {
        relayout_uia_read_selection($0.baseAddress, Int32($0.count))
    }
    guard n >= 0 else { return nil }
    return String(decoding: buf.prefix(Int(n)), as: UTF16.self)
}

/// The focused field as the Enter follow-up needs it (`FieldSnapshot` from the
/// engine): total length, caret offset, selection length, and the text before the
/// caret.
/// - Returns: nil when the control exposes no UI Automation text.
func readFieldSnapshot() -> FieldSnapshot? {
    var buf = [UInt16](repeating: 0, count: 128)
    var count: Int32 = 0, caret: Int32 = 0, selected: Int32 = 0
    let ok = buf.withUnsafeMutableBufferPointer {
        relayout_uia_snapshot($0.baseAddress, Int32($0.count), &count, &caret, &selected)
    }
    guard ok == 0 else { return nil }
    return FieldSnapshot(count: Int(count), caret: Int(caret), selected: Int(selected),
                         tail: String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF16.self))
}
