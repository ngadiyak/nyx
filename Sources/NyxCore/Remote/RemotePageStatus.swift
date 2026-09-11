import Foundation

/// Why the Remote page's Pair buttons are disabled, in a sentence that names the remedy — and
/// whether they are disabled at all.
///
/// The owner pressed Pair on 2026-09-07, found it dead, and could not see why: the page's status
/// line was three hundred points above the buttons with a table of paired devices between them.
/// A disabled primary button has to explain itself *beside itself*. Keeping it disabled rather than
/// enabling it and routing to the empty field is the ruling of spec §5.3: an enabled button that
/// does not do what it says is a second lie on top of the first.
public enum RemotePageStatus {
    public static func text(mode: RemoteMode, relay: String,
                            token: String) -> (sentence: String, blocksPairing: Bool) {
        guard mode == .on else {
            return ("Remote sessions are off — tick Enable remote sessions to pair.", true)
        }
        guard !relay.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ("Pairing needs a relay — set Relay above.", true)
        }
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ("Pairing needs a relay token — set Relay token above.", true)
        }
        return ("Ready to pair. Both Macs must reach the same relay.", false)
    }
}

/// The Remote page's own words, in Core so that the page and its picture cannot drift and so the
/// sentences are read once, here, rather than in a layout method.
public enum RemotePageCopy {
    /// What the feature is. The page named the relay's metadata exposure at the very bottom and
    /// never said what a remote session was or where a relay came from -- which is the whole of
    /// what somebody setting this up for the first time needs.
    public static let what = "A remote session is a Nyx tab on another of your Macs, reached "
        + "through a relay both machines dial out to. Nyx never sends terminal text the relay can read."

    public static let relay = "The relay URL and token come from the nyx-server you run; "
        + "Nyx cannot issue them."

    /// What `Snapshot lines` costs. Measured: 2,000 lines of a real session sealed into six frames
    /// of about 85 KB, and it is sent again on every attach.
    public static func snapshotCost(lines: Int) -> String {
        let kb = max(1, Int((Double(lines) * 43.5 / 1024).rounded()))
        return "How much scrollback a Mac attaching to this one receives: about \(kb) KB at "
            + "\(lines) lines, sent once per attach."
    }
}
