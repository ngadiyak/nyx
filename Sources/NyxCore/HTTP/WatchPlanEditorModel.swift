import Foundation

/// The `Watch…` popover's fields, and what they add up to.
///
/// Every field is a `String` because every field is a text box or a pop-up: the model holds what
/// the user has typed, not what it wishes they had typed. That is the difference between a form
/// that says "Seconds must be a number between 0.5 and 3600" while you are half way through typing
/// `0.` and one that silently rewrites it to `0` under the cursor.
///
/// `plan` is nil for exactly as long as `problem` is not: the popover's Start button is
/// `plan != nil`, so there is one rule for "can this run" rather than a validation in the model and
/// an enablement in the view that can disagree.
public struct WatchPlanEditorModel: Equatable {
    /// Which of `WatchPlan.Stop`'s three shapes the popover is currently describing. A separate
    /// enum from `Stop` itself because a half-typed count is still the `count` shape: the pop-up
    /// choice has to survive a field the model cannot read yet.
    public enum StopKind: String, CaseIterable, Equatable {
        case never, count, until

        /// The pop-up's rows.
        public var title: String {
            switch self {
            case .never: return "Until I stop it"
            case .count: return "After a number of runs"
            case .until: return "Until a condition holds"
            }
        }
    }

    /// `WatchPlan.Condition` without its payload -- the same reason `StopKind` exists.
    public enum ConditionKind: String, CaseIterable, Equatable {
        case status, statusClass, statusNot, bodyContains, bodyLacks

        public var title: String {
            switch self {
            case .status: return "Status is"
            case .statusClass: return "Status class is"
            case .statusNot: return "Status is not"
            case .bodyContains: return "Body contains"
            case .bodyLacks: return "Body lacks"
            }
        }

        /// What the field beside the pop-up is for, so an empty box is never a mystery.
        public var placeholder: String {
            switch self {
            case .status, .statusNot: return "200"
            case .statusClass: return "2"
            case .bodyContains, .bodyLacks: return "ready"
            }
        }
    }

    public var interval: String
    public var stop: StopKind = .never
    public var count: String = "10"
    public var condition: ConditionKind = .status
    public var value: String = "200"

    /// Seeded from `http-watch-interval`, so the popover opens on the interval the ⋯ menu's
    /// "Run Every 5 s" row and the sheet's "Run every…" already offer.
    public init(interval: Double) {
        self.interval = WatchPlan.secondsText(interval)
    }

    // MARK: - Validation

    /// Below half a second a watch is a load test, and `RequestEditor.askForInterval` already
    /// clamps to it: two entry points to the same series must not disagree about what is allowed.
    /// The ceiling is `http-watch-interval`'s own, an hour.
    public static let minimumInterval: Double = 0.5
    public static let maximumInterval: Double = 3600

    public var intervalProblem: String? {
        guard let seconds = WatchPlanEditorModel.number(interval), seconds.isFinite,
              seconds >= WatchPlanEditorModel.minimumInterval,
              seconds <= WatchPlanEditorModel.maximumInterval else {
            return "Seconds must be a number between "
                + WatchPlan.secondsText(WatchPlanEditorModel.minimumInterval) + " and "
                + WatchPlan.secondsText(WatchPlanEditorModel.maximumInterval) + "."
        }
        return nil
    }

    /// nil unless the count field is the one being read: a stale `0` left in the box while the
    /// stop rule is "until I stop it" is not a reason to refuse to start.
    public var countProblem: String? {
        guard stop == .count else { return nil }
        guard let times = Int(count.trimmingCharacters(in: .whitespaces)), times >= 1 else {
            return "Runs must be a whole number, at least 1."
        }
        return nil
    }

    public var conditionProblem: String? {
        guard stop == .until else { return nil }
        let text = value.trimmingCharacters(in: .whitespaces)
        switch condition {
        case .status, .statusNot:
            guard let code = Int(text), (100...599).contains(code) else {
                return "A status is a number from 100 to 599."
            }
        case .statusClass:
            guard let hundreds = Int(text), (1...5).contains(hundreds) else {
                return "A status class is a single digit from 1 to 5 -- 2 for any 2xx."
            }
        case .bodyContains, .bodyLacks:
            guard !text.isEmpty else { return "Type the text to look for in the body." }
        }
        return nil
    }

    /// The first thing wrong, in the order the fields are read down the popover, so the sentence
    /// under them names the box the user should look at first.
    public var problem: String? { intervalProblem ?? countProblem ?? conditionProblem }

    /// The plan these fields describe, or nil while any of them cannot be read.
    public var plan: WatchPlan? {
        guard problem == nil, let seconds = WatchPlanEditorModel.number(interval) else { return nil }
        let text = value.trimmingCharacters(in: .whitespaces)
        let rule: WatchPlan.Stop
        switch stop {
        case .never:
            rule = .never
        case .count:
            guard let times = Int(count.trimmingCharacters(in: .whitespaces)) else { return nil }
            rule = .count(times)
        case .until:
            switch condition {
            case .status:
                guard let code = Int(text) else { return nil }
                rule = .until(.status(code))
            case .statusClass:
                guard let hundreds = Int(text) else { return nil }
                rule = .until(.statusClass(hundreds))
            case .statusNot:
                guard let code = Int(text) else { return nil }
                rule = .until(.statusNot(code))
            case .bodyContains: rule = .until(.bodyContains(text))
            case .bodyLacks: rule = .until(.bodyLacks(text))
            }
        }
        return WatchPlan(interval: seconds, stop: rule)
    }

    /// What the popover's own summary line reads, in the same words the block header will use once
    /// the series is running -- and empty while the fields do not describe a plan, because a title
    /// over a Start button nobody can press is a description of nothing.
    public var title: String { plan?.title ?? "" }

    /// `Double(_:)` with the locale left out of it deliberately: a text field on a German system
    /// takes `0,5`, and a plan built from `0` seconds is a fork bomb with a curl in it. Refusing
    /// what cannot be read as a plain number is the safe half of that trade.
    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces))
    }
}
