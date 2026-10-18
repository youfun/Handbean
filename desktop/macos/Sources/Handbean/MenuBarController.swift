import AppKit

/// Phase 2 menu bar. Phase 1 installs no status item.
///
/// Do not render this menu in WKWebView. Use `NSStatusItem` + `NSMenu` so
/// shortcuts, checkmarks, and VoiceOver stay native. A richer picker, if one
/// is needed later, belongs in `NSPopover` + SwiftUI, separate from the chat
/// web view.
///
/// Planned menu, once a sessions API exists (until then, UserDefaults placeholders):
/// - Pinned threads, ⌘1…⌘8
/// - Recent threads, ⌘9
/// - New Thread…, ⌃⌥N
/// - Keep This Mac Awake (checkmark, persisted; `ProcessInfo.beginActivity`
///   with `.idleSystemSleepDisabled`, or `caffeinate`)
/// - Open Handbean (show the existing WKWebView window; do not start a second backend)
/// - Menu Bar Settings…
/// - Quit Handbean, ⌘Q
///
/// Session switches should focus the window and load `/sessions/:id` (or call
/// into the page). They must not embed the LiveView UI in the status item.
///
/// When the status item is installed, set `shouldTerminateWhenLastWindowClosed`
/// to false and keep the backend running until Quit. `LSUIElement` / accessory
/// activation is a setting, not the phase 1 default. Global hotkeys that need
/// Accessibility permission are out of scope; menu key equivalents are enough.
@MainActor
final class MenuBarController: NSObject {
    /// Phase 1 has no status item, so closing the last window quits the app.
    var shouldTerminateWhenLastWindowClosed: Bool { true }

    func install() {}

    func setKeepAwake(_ enabled: Bool) {
        _ = enabled
    }
}
