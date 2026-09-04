//
//  MediaPauser.swift
//  slapss
//
//  Pauses whatever is playing audio, just before a meeting join URL opens.
//
//  Uses the system Play/Pause media key rather than Apple events. Apple events
//  can drive Music, Spotify and TV, but Safari and Chrome expose only
//  JavaScript injection, gated behind a developer setting that is off by
//  default — so the browser tab that is actually making the noise during a
//  workday is unreachable that way. The media key reaches it, and needs no new
//  entitlement: Accessibility is a TCC grant, not an entitlement.
//
//  The key is a TOGGLE, not a pause, so posting it when nothing is playing can
//  START playback. Which means this is only safe behind a gate that can answer
//  "is something audible right now" — and no such gate exists yet. See
//  `shouldPause`.

import AppKit
import CoreAudio

@MainActor
enum MediaPauser {

    /// Sends the system Play/Pause **toggle**, if `shouldPause` allows it.
    ///
    /// Named for what it sends rather than for an outcome: nothing here can tell
    /// whether the result was a pause or a start. See `shouldPause`.
    static func sendPlayPauseToggle() {
        guard shouldPause() else { return }
        postPlayPauseKey()
    }

    /// **The gate, and it is not settled.** One call so the policy can be
    /// replaced without touching the hook in `MeetingURLOpener` or the actuator
    /// below — the candidates put different things here: Apple events only
    /// (exact, but blind to browsers), the key ungated (accepts that it can
    /// start playback), or the key gated by Apple events (browsers uncovered).
    ///
    /// What it currently asks is **not** the question that makes this safe.
    /// `anyProcessHoldsOpenOutputStream` is the closest public signal and it is
    /// the wrong one: see its docstring.
    private static func shouldPause() -> Bool {
        anyProcessHoldsOpenOutputStream
    }

    /// Whether any process holds an **open audio output stream** — which is not
    /// the same as anything being audible, and the difference is the problem.
    ///
    /// `kAudioProcessPropertyIsRunningOutput` is documented in `AudioHardware.h`
    /// as "running IO and there is at least one active output stream". Measured:
    /// a process emitting pure silence reads 1, and a *paused* player whose
    /// engine is still running reads 1 indefinitely. The flag falls the instant
    /// the stream actually closes, so there is no idle timeout to wait out — the
    /// fall is whenever the app in question decides to tear its stream down,
    /// which is per-app and unbounded.
    ///
    /// So this returns true for the most ordinary state slapss runs in: a
    /// conferencing call holds an output stream for its whole duration, and
    /// Safari's WebKit GPU process holds one most of the time with nothing
    /// playing. Gating on it means a back-to-back meeting posts the key with
    /// nothing to pause, and macOS routes it to the last media app — starting
    /// playback, which is the outcome the gate was meant to prevent.
    ///
    /// Filtering by bundle id does not rescue it: Safari's WebKit GPU process
    /// is both the media producer and the Google Meet producer, so "playing
    /// YouTube" and "in a Meet call" are indistinguishable here.
    ///
    /// None of the six process properties in that header measure audibility.
    static var anyProcessHoldsOpenOutputStream: Bool {
        audioProcessObjects().contains { object in
            uint32Property(object, kAudioProcessPropertyIsRunningOutput) == 1
        }
    }

    /// Whether this process may post synthetic events, for Settings to render a
    /// "grant Accessibility" affordance against.
    ///
    /// Deliberately not used to gate `sendPlayPauseToggle` — it answers for the
    /// *responsible* process, not this binary, so a build launched from a
    /// terminal that itself holds Accessibility reads `true` while its posts
    /// are dropped. Inside a normally launched .app the responsible process is
    /// the app, which is the only context this is read from.
    static var canPostSyntheticEvents: Bool { CGPreflightPostEventAccess() }

    /// Asks for post-event access, which adds slapss to System Settings →
    /// Privacy & Security → Accessibility as an **unchecked** row.
    ///
    /// It returns `false` immediately and raises no prompt, so a caller must
    /// not treat the return value as a decision or wait for a dialog — the user
    /// still has to flip the switch themselves. Called only to create the row,
    /// so that "Open System Settings" lands somewhere with slapss already in it.
    @discardableResult
    static func requestAccessibilityRow() -> Bool { CGRequestPostEventAccess() }

    // MARK: - Media key

    // From IOKit's `ev_keymap.h` and `IOLLEvent.h`, neither of which has a
    // Swift overlay, so the values are restated here.
    private static let playPauseKeyCode: Int32 = 16   // NX_KEYTYPE_PLAY
    private static let keyDown = 0x0a                 // NX_KEYDOWN
    private static let keyUp = 0x0b                   // NX_KEYUP
    private static let auxControlButtons = 8          // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    /// Both down and up are required; a lone down event is ignored.
    private static func postPlayPauseKey() {
        for isDown in [true, false] {
            let state = isDown ? keyDown : keyUp
            let data1 = Int((playPauseKeyCode << 16) | Int32(state << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(auxControlButtons),
                data1: data1,
                data2: -1
            ), let cgEvent = event.cgEvent else { return }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - CoreAudio

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func uint32Property(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object, &address, 0, nil, &size, &value
        ) == noErr else { return 0 }
        return value
    }
}
