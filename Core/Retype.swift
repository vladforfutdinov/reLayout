/// Where the hotkey's text comes from.
public enum RetypeSource: Equatable {
    /// The selection the accessibility API read.
    case selection(String)
    /// The word auto mode saw typed before the caret (and the spaces after it).
    case typedWord
    /// Copy the selection with a synthetic Copy and read the clipboard (then put
    /// the user's clipboard back); if it copies nothing, the typed word.
    case clipboardProbe
    case nothing
}

/// The hotkey's source of text, the same rule in both apps.
/// - Parameters:
///   - selection: the accessibility API's read: nil when it gives no text for the
///     control, "" when it says nothing is selected.
///   - hasTypedWord: auto mode saw a word typed before the caret.
///   - console: a console, where a synthetic Copy would interrupt (Windows).
///   - probeBlocked: a probe found nothing a moment ago; a second synthetic Copy
///     right away could fire another app's double-copy shortcut (DeepL).
public func retypeSource(selection: String?, hasTypedWord: Bool, console: Bool = false,
                         probeBlocked: Bool) -> RetypeSource {
    if console { return hasTypedWord ? .typedWord : .nothing }
    if let s = selection, !s.isEmpty { return .selection(s) }
    // "Nothing selected" is not always true (VS Code says so for a real selection
    // unless its accessibility support is on): with no typed word, ask the clipboard.
    if selection != nil, hasTypedWord { return .typedWord }
    if probeBlocked { return hasTypedWord ? .typedWord : .nothing }
    return .clipboardProbe
}
