/// A conversion just typed (by the hotkey or auto mode), kept so that the next
/// hotkey press can retype the original into the next layout or put it back.
/// `Src` is how a platform names the layout to return to, `Dst` a layout it types in.
public struct Conversion<Src, Dst> {
    public let original: String
    public var typed: String
    public let src: Src
    /// Hotkey misses this conversion learned: undo forgets them.
    public var learned: [String]
    /// Words an auto-correction fixed: undo learns them as `keep`.
    public var autoWords: [String]
    /// The other readings of `original` (engine `retypeAlternatives`), next press first.
    public var alternatives: [(out: String, dst: Dst)]
    /// Spaces after a typed word, kept on a retarget.
    public var suffix: String

    public init(original: String, typed: String, src: Src, learned: [String] = [], autoWords: [String] = [],
                alternatives: [(out: String, dst: Dst)] = [], suffix: String = "") {
        self.original = original; self.typed = typed; self.src = src; self.learned = learned
        self.autoWords = autoWords; self.alternatives = alternatives; self.suffix = suffix
    }
}

/// What the next hotkey press does with the last conversion.
public enum PressAgainStep<Src, Dst> {
    /// Erase `erase` characters, type `type` in `dst`, then record `then`.
    case retarget(erase: Int, type: String, dst: Dst, then: Conversion<Src, Dst>)
    /// Erase what was typed and put the original back (`Conversion.src`).
    case undo(Conversion<Src, Dst>)
}

/// The press-again record both apps keep. Any key or click of the user's ends it
/// (`forget`); a conversion typed while one arrived is not recorded (`mark`/`record`),
/// since its undo would erase at a caret that has moved.
public struct PressAgain<Src, Dst> {
    private var last: Conversion<Src, Dst>?
    private var epoch = 0

    public init() {}

    /// Taken when a conversion starts; pass it to `record`.
    public var mark: Int { epoch }

    /// Records `c` unless the user typed or clicked since `mark`.
    public mutating func record(_ c: Conversion<Src, Dst>, since mark: Int) {
        if mark == epoch { last = c }
    }

    /// The user typed or clicked: the record ends, and conversions under way are not recorded.
    public mutating func forget() { last = nil; epoch &+= 1 }

    /// Ends the record only: a key that may itself be starting a correction must not
    /// keep that correction from being recorded.
    public mutating func drop() { last = nil }

    /// The step for a hotkey press, if there is a record; the record is taken.
    public mutating func next() -> PressAgainStep<Src, Dst>? {
        guard let c = last else { return nil }
        last = nil
        guard let n = c.alternatives.first else { return .undo(c) }
        var then = c
        then.typed = n.out + c.suffix
        then.alternatives.removeFirst()
        return .retarget(erase: c.typed.count, type: then.typed, dst: n.dst, then: then)
    }
}
