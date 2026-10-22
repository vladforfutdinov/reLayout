/// A yes/no fact about the focused control that is asked asynchronously — "is it
/// a password field?" — and must fail closed: while an answer is on its way, auto
/// mode corrects nothing. Each question has a number; an answer counts only for
/// the latest one (it may have been asked for another field), a stale one asks again.
public struct FieldCheck {
    public private(set) var value = false
    /// Not known for the focused control now.
    public private(set) var pending = false
    private var inFlight = false
    private var current = 0

    public init() {}

    /// Nothing may be corrected: the answer is yes, or not known yet.
    public var blocks: Bool { value || pending }
    /// Typed keys are dropped: the answer is a known yes. While pending they are
    /// kept (in memory only), since the last answer may be about another field.
    public var dropsKeys: Bool { value && !pending }

    /// A new word starts: the answer is needed again.
    /// - Returns: the question to send, or nil when one is on its way already (it
    ///   is asked again when its answer lands).
    public mutating func needed() -> Int? {
        current &+= 1
        pending = true
        guard !inFlight else { return nil }
        inFlight = true
        return current
    }

    /// The question could not be sent.
    public mutating func unsent() { inFlight = false }

    /// The answer to question `n`.
    /// - Returns: a question to send instead, when `n` is no longer the latest.
    public mutating func answered(_ v: Bool, for n: Int) -> Int? {
        guard n == current else { return current }
        value = v
        pending = false
        inFlight = false
        return nil
    }

    /// Answered right here (a synchronous read); an answer still on its way is stale.
    public mutating func set(_ v: Bool) {
        current &+= 1
        value = v
        pending = false
    }

    /// Focus may have moved and a read now could still see the old control:
    /// unknown until the next word asks.
    public mutating func invalidate() {
        current &+= 1
        pending = true
    }
}
