/// The keystroke gate both apps close while a correction retypes a word: keys typed
/// meanwhile are held, then replayed after it in order, so none lands between the
/// correction's deletes and its retype. A correction that takes longer than
/// `maxHold` is treated as stuck: the gate opens and hands back everything it held.
/// Times are seconds on any monotonic clock.
public struct KeyGate<Key> {
    public enum Decision {
        /// The gate is open: the key goes on as usual.
        case pass
        /// Held; it is replayed after the correction.
        case hold
        /// The correction is stuck: send these keys, in order (the held ones, then
        /// this one), and drop the correction. The gate is open again.
        case release([Key])
    }

    public let maxHold: Double
    public private(set) var held: [Key] = []
    private var since: Double?

    public init(maxHold: Double = 3) { self.maxHold = maxHold }

    /// Keys are being held (a correction or its replay is under way).
    public var isClosed: Bool { since != nil }

    /// A correction starts: keys are held from now.
    public mutating func close(at now: Double) { since = now }

    /// Opens the gate and forgets what it held (nothing left to replay, or the
    /// monitor stopped).
    public mutating func open() { since = nil; held = [] }

    /// A key that types text.
    public mutating func key(_ k: Key, at now: Double) -> Decision {
        guard let since else { return .pass }
        guard now - since <= maxHold else {
            let out = held + [k]
            open()
            return .release(out)
        }
        held.append(k)
        return .hold
    }

    /// Backspace while keys are held un-types the last one instead of reaching the
    /// app out of order; a wide delete (word, line) drops them all and goes on.
    /// - Returns: true when the backspace was consumed.
    public mutating func backspace(wide: Bool) -> Bool {
        if wide { held = []; return false }
        guard isClosed, !held.isEmpty else { return false }
        held.removeLast()
        return true
    }

    /// The next held key to replay, oldest first; nil when none is left. The gate
    /// stays closed, so keys typed during the replay queue behind it; the clock
    /// restarts with each replayed key.
    public mutating func nextToReplay(at now: Double) -> Key? {
        guard !held.isEmpty else { return nil }
        if since != nil { since = now }
        return held.removeFirst()
    }
}
