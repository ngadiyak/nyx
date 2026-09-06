import Foundation

/// How old something is, written the way a list is read rather than the way a clock is.
///
/// One function for every palette section: the Remote rows had their own copy of these buckets and
/// the Requests rows would have grown a second, which is how one list ends up saying "1 h ago" and
/// "60 min ago" about the same moment. Buckets get coarser as they get older -- minutes are worth
/// counting exactly, days are not.
public enum RelativeAge {
    public static func text(from: Date, to: Date) -> String {
        // A negative elapsed time is a clock that moved -- a restored session, an NTP resync -- and
        // "-3 min ago" is worse than the rounding it would replace.
        let elapsed = max(0, to.timeIntervalSince(from))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed) / 60) min ago" }
        if elapsed < 86_400 { return "\(Int(elapsed) / 3600) h ago" }
        if elapsed < 172_800 { return "yesterday" }
        return "\(Int(elapsed) / 86_400) days ago"
    }
}
