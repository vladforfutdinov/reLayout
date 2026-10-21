/// A hotkey recorded as several presses (a double tap of Shift): it fires on the
/// last one, each within `window` seconds of the one before. Both apps use it.
public struct TapSequence {
    public let window: Double
    private var count = 0
    private var last = -Double.infinity

    public init(window: Double = 0.5) { self.window = window }

    /// One activation of the hotkey's keys.
    /// - Parameter taps: presses the hotkey needs (1 fires at once).
    /// - Returns: true when this activation completes the sequence.
    public mutating func activate(at now: Double, taps: Int) -> Bool {
        guard taps > 1 else { return true }
        count = now - last <= window ? count + 1 : 1
        last = now
        guard count >= taps else { return false }
        count = 0
        return true
    }

    public mutating func reset() { count = 0; last = -.infinity }
}

/// A hotkey made of modifier keys alone (left Option, Ctrl+Shift): it activates when
/// exactly that chord is pressed and released quickly, with no other key, click or
/// modifier in between. Fed the set of modifiers held after every change.
public struct ModifierTap<Mod: Hashable> {
    public let maxHold: Double
    private var armed = false, armTime = 0.0
    private var interrupted = false   // a key or click during the hold
    private var polluted = false      // a modifier outside the chord appeared this cycle

    public init(maxHold: Double = 0.6) { self.maxHold = maxHold }

    /// A key or click while modifiers are held: this press is no tap.
    public mutating func interrupt() { interrupted = true; armed = false }

    /// The held modifiers changed.
    /// - Parameters:
    ///   - held: the modifiers held now.
    ///   - chord: the hotkey's modifiers.
    /// - Returns: true when this change released a clean tap of `chord`.
    public mutating func changed(held: Set<Mod>, chord: Set<Mod>, at now: Double) -> Bool {
        guard !chord.isEmpty else { return false }
        if held.isEmpty {
            let fire = armed && !interrupted && !polluted && now - armTime < maxHold
            armed = false
            polluted = false
            return fire
        }
        if !held.isSubset(of: chord) {
            // Another modifier joined: the whole press is poisoned, so letting go of
            // it back to the chord cannot arm again.
            polluted = true
            armed = false
        } else if held == chord, !polluted, !armed {
            armed = true
            armTime = now
            interrupted = false
        }
        // A strict subset: the chord is still building up or being released.
        return false
    }
}
