import AppKit
import Darwin
import HandbeanCore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: SingleInstanceLock?
    private var menuBar: MenuBarController?
    private var backend: BackendController?
    private var verificationBridge: ComputerBridge?
    private var windows: WebWindowController?
    private var activity: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
    private var visibilityObservers: [NSObjectProtocol] = []

    static func main() {
        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--printenv" {
            if let data = DesktopEnvironment.encoded(ProcessInfo.processInfo.environment) {
                FileHandle.standardOutput.write(data)
                return
            }
            exit(1)
        }
        if CommandLine.arguments.count == 3 &&
            CommandLine.arguments[1] == "--capture-shell-environment" {
            let inherited = ProcessInfo.processInfo.environment
            let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            if let environment = DesktopEnvironment.capture(
                directory: CommandLine.arguments[2],
                inherited: inherited,
                helper: helper
            ), let data = DesktopEnvironment.encoded(environment) {
                FileHandle.standardOutput.write(data)
                return
            }
            exit(1)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--computer-use-verification" {
            startComputerVerification(directory: CommandLine.arguments[2])
            return
        }
        // The disposable bundle must stay verification-only after TCC's
        // Quit & Reopen, which does not preserve command-line arguments.
        if Bundle.main.bundleIdentifier == "com.youfun.handbean.computerverification" {
            guard let directory = Bundle.main.object(forInfoDictionaryKey: "HandbeanComputerVerificationDirectory") as? String else {
                NSApp.terminate(nil)
                return
            }
            startComputerVerification(directory: directory)
            return
        }
        guard let instanceLock = SingleInstanceLock.acquire() else {
            activateExistingInstance()
            NSApp.terminate(nil)
            return
        }
        self.instanceLock = instanceLock

        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.regular)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Handbean local UI"
        )
        installSignalForwarding()
        installMainMenu()

        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar

        MacNotifications.shared.install()
        installVisibilityObservers()

        let backend = BackendController()
        let window = WebWindowController()
        window.onRetry = { [weak backend] in
            backend?.start()
        }
        backend.onChange = { [weak window] state in
            window?.apply(state)
        }
        self.backend = backend
        self.windows = window
        MacNotifications.shared.setOpenHandler { [weak window] workspaceID, conversationID in
            window?.showConversation(workspaceID: workspaceID, conversationID: conversationID)
        }
        backend.appVisible = { [weak self] in
            self?.appIsVisible() ?? true
        }
        window.show()
        window.apply(.starting)
        publishAppVisibility()
        backend.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        verificationBridge?.stop()
        backend?.stopOwnedBackend()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if verificationBridge != nil { return false }
        return menuBar?.shouldTerminateWhenLastWindowClosed ?? true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windows?.show()
        }
        return true
    }

    private func installVisibilityObservers() {
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.publishAppVisibility()
            }
            visibilityObservers.append(token)
        }
    }

    private func publishAppVisibility() {
        let visible = appIsVisible()
        Task { @MainActor in
            self.backend?.noteAppVisibility(visible)
        }
    }

    private func appIsVisible() -> Bool {
        guard let window = windows?.window else { return false }
        return NSApp.isActive && window.isVisible && !window.isMiniaturized &&
            window.occlusionState.contains(.visible)
    }

    private func activateExistingInstance() {
        let current = ProcessInfo.processInfo.processIdentifier

        NSRunningApplication.runningApplications(withBundleIdentifier: DesktopConfig.bundleIdentifier)
            .first(where: { $0.processIdentifier != current })?
            .activate(options: [])
    }

    private func installSignalForwarding() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Handbean", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Handbean", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Stop Computer Use", action: #selector(stopComputerUse), keyEquivalent: ".")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Handbean", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @MainActor @objc private func stopComputerUse(_ sender: Any?) {
        verificationBridge?.controller.stop()
        backend?.stopComputerUse()
    }

    // Manual-only harness: no BEAM, no production storage, no bypass of TCC
    // or native consent. Its bridge can select only the dedicated fixture app.
    private func startComputerVerification(directory: String) {
        NSApp.setActivationPolicy(.regular)
        installSignalForwarding()
        installMainMenu()
        Task { @MainActor in
            do {
                let directoryURL = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath()
                let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
                guard directory.hasPrefix("/"), attributes[.type] as? FileAttributeType == .typeDirectory,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      let permissions = attributes[.posixPermissions] as? NSNumber,
                      permissions.intValue & 0o077 == 0 else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let bridge = try ComputerBridge(verificationOnly: true)
                let environment = try await bridge.start()
                self.verificationBridge = bridge
                let url = directoryURL.appendingPathComponent("bridge.json")
                let data = try JSONSerialization.data(withJSONObject: environment)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Computer Use verification could not start"
                alert.informativeText = String(describing: error)
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Handbean",
            .applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "",
        ])
    }
}

private final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() -> SingleInstanceLock? {
        let fileManager = FileManager.default
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Handbean", isDirectory: true)

        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let lockURL = support.appendingPathComponent("app.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        return SingleInstanceLock(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
