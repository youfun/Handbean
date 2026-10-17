import AppKit
import ApplicationServices
import CryptoKit
import ScreenCaptureKit

/// Only public APIs. Input is foreground-only; capture remains window scoped.
struct ComputerTarget {
    let appID: String
    let pid: pid_t
    let launched: Date?
    let windowID: CGWindowID
    let title: String

    enum Refusal: Error { case forbidden, unavailable, ambiguousWindow, permission, focus, dialog, imageTooLarge }

    static func allowed(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, app.processIdentifier != getpid(),
              app.activationPolicy == .regular else { return false }
        let identity = (id + " " + (app.localizedName ?? "")).lowercased()
        let forbidden = ["handbean", "terminal", "iterm", "warp", "ghostty", "alacritty", "wezterm", "kitty", "xterm", "securityagent", "coreauth", "systempreferences", "system settings", "loginwindow", "keychain", "passwords", "authenticator", "visual studio code", "com.microsoft.vscode", "cursor", "xcode"]
        return !forbidden.contains(where: identity.contains)
    }

    static func windows() -> [[String: Any]] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    static func inventory() -> [[String: Any]] {
        windows().compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid), allowed(app),
                  let id = app.bundleIdentifier,
                  let window = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            return ["app_id": id, "app_name": app.localizedName ?? id, "window_id": window,
                    "title": info[kCGWindowName as String] as? String ?? ""]
        }
    }

    static func select(appID: String, windowID: UInt32) throws -> ComputerTarget {
        let matches = windows().filter { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return info[kCGWindowNumber as String] as? UInt32 == windowID && app.bundleIdentifier == appID && allowed(app)
        }
        guard matches.count == 1, let info = matches.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let app = NSRunningApplication(processIdentifier: pid) else { throw Refusal.forbidden }
        return ComputerTarget(appID: appID, pid: pid, launched: app.launchDate,
                              windowID: windowID, title: info[kCGWindowName as String] as? String ?? "")
    }

    func bounds() throws -> CGRect {
        guard let app = NSRunningApplication(processIdentifier: pid), Self.allowed(app),
              app.bundleIdentifier == appID, app.launchDate == launched,
              let info = Self.windows().first(where: { $0[kCGWindowNumber as String] as? UInt32 == windowID && $0[kCGWindowOwnerPID as String] as? pid_t == pid }),
              (info[kCGWindowName as String] as? String ?? "") == title,
              let value = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: value as CFDictionary),
              rect.width > 1, rect.height > 1 else { throw Refusal.unavailable }
        return rect
    }

    func activate() async throws {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(), CGPreflightPostEventAccess() else { throw Refusal.permission }
        let window = try axWindow()
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
              NSRunningApplication(processIdentifier: pid)?.activate(options: []) == true else { throw Refusal.focus }
        await Task.yield()
        try checkFocus()
    }

    func checkFocus() throws {
        guard unlocked(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Refusal.focus }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let focused = element(app, kAXFocusedWindowAttribute),
              sameWindow(focused, try bounds()),
              value(focused, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              let children = value(focused, kAXChildrenAttribute) as? [AXUIElement],
              children.count <= 250,
              !children.contains(where: { value($0, kAXRoleAttribute) as? String == kAXSheetRole || value($0, kAXSubroleAttribute) as? String == kAXDialogSubrole }) else { throw Refusal.dialog }
        if let element = element(app, kAXFocusedUIElementAttribute) {
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            let subrole = value(element, kAXSubroleAttribute) as? String ?? ""
            guard !role.lowercased().contains("secure"), !subrole.lowercased().contains("secure") else { throw Refusal.dialog }
        }
    }

    func capture() async throws -> (CGImage, Data, CGRect) {
        guard unlocked(), CGPreflightScreenCaptureAccess() else { throw Refusal.permission }
        let before = try bounds()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == pid }) else { throw Refusal.unavailable }
        let config = SCStreamConfiguration()
        let scale = min(2.0, 2048 / max(before.width, before.height))
        config.width = Int((before.width * scale).rounded())
        config.height = Int((before.height * scale).rounded())
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        guard before == (try bounds()) else { throw Refusal.unavailable }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 5_000_000 else { throw Refusal.imageTooLarge }
        return (image, data, before)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func axWindow() throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let rect = try bounds()
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { throw Refusal.ambiguousWindow }
        let matches = windows.filter { sameWindow($0, rect) }
        guard matches.count == 1, let window = matches.first else { throw Refusal.ambiguousWindow }
        AXUIElementSetMessagingTimeout(window, 0.3)
        return window
    }

    private func sameWindow(_ window: AXUIElement, _ rect: CGRect) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.3)
        guard let rawPosition = value(window, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = value(window, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return false }
        let position = unsafeBitCast(rawPosition, to: AXValue.self)
        let size = unsafeBitCast(rawSize, to: AXValue.self)
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return false }
        return CGRect(origin: p, size: s) == rect && (value(window, kAXTitleAttribute) as? String ?? "") == title
    }

    private func element(_ app: AXUIElement, _ key: String) -> AXUIElement? {
        guard let raw = value(app, key), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private func unlocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true && session[kCGSessionOnConsoleKey as String] as? Bool == true
    }
}
