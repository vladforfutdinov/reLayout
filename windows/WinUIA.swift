import RelayoutUIA

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
