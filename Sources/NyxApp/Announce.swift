import AppKit

/// One place that speaks to VoiceOver.
///
/// `.announcementRequested` on the application, because the thing being announced is not a change
/// to any one element's value -- a command finishing belongs to the pane, a banner to the window.
/// The wording never lives here: it comes from Core (`BlockHeader.summary`, `ConfigDiagnostic`,
/// `SearchSession`'s readout, `WatchPlanEditorModel.problem`), so what is spoken and what is on the
/// screen cannot drift apart.
enum Announce {
    static func say(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
