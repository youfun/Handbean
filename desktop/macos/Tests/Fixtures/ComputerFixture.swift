import AppKit
import CoreGraphics

// A disposable app with no network, shell, document opening or user-data access.
// Record received events, not generated ones: real PID delivery must be verified
// without this fixture manufacturing input or granting any permission.
@main
final class ComputerFixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var field: NSTextField!
    private var countLabel: NSTextField!
    private var button: NSButton!
    private var scroll: NSScrollView!
    private var eventMonitor: Any?
    private var events: [[String: Any]] = []
    private var clicks = 0
    static func main() {
        let app = NSApplication.shared
        let delegate = ComputerFixture()
        app.delegate = delegate
        app.run()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 450), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Computer Use Fixture — disposable"
        field = NSTextField(frame: CGRect(x: 40, y: 340, width: 400, height: 30))
        field.placeholderString = "Type only test text here"
        field.delegate = self
        window.contentView?.addSubview(field)
        button = NSButton(title: "Increment test counter", target: self, action: #selector(increment))
        button.frame = CGRect(x: 40, y: 280, width: 240, height: 35)
        window.contentView?.addSubview(button)
        countLabel = NSTextField(labelWithString: "Clicks: 0")
        countLabel.frame = CGRect(x: 320, y: 285, width: 180, height: 30)
        window.contentView?.addSubview(countLabel)
        scroll = NSScrollView(frame: CGRect(x: 40, y: 40, width: 500, height: 210))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 480, height: 1200))
        text.isEditable = false
        text.string = (1...40).map { "Disposable scroll row \($0)" }.joined(separator: "\n")
        scroll.documentView = text
        window.contentView?.addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged, .scrollWheel, .keyDown, .keyUp]) { [weak self] event in
            // A receive-and-suppress probe verifies PID/window annotation
            // without invoking a button, text responder or scroll view.
            let suppress = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x484250524F42
            self?.record(event, suppressed: suppress)
            return suppress ? nil : event
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeReport()
    }
    @objc private func increment() { clicks += 1; countLabel.stringValue = "Clicks: \(clicks)"; writeReport() }
    @objc private func scrollChanged(_ notification: Notification) { writeReport() }
    func controlTextDidChange(_ notification: Notification) { writeReport() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func record(_ event: NSEvent, suppressed: Bool) {
        let selectedWindow = event.window === window
        var hit: NSView?
        if selectedWindow, let content = window.contentView {
            // hitTest takes a point in the view's superview coordinate space.
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            hit = content.hitTest(point)
        }
        var entry: [String: Any] = ["type": event.type.rawValue, "window_number": event.windowNumber,
                                    "resolved_window_number": event.window?.windowNumber ?? 0,
                                    "selected_window": selectedWindow,
                                    "suppressed_probe": suppressed,
                                    "hit_counter_button": hit?.isDescendant(of: button) == true,
                                    "hit_scroll": hit?.isDescendant(of: scroll) == true,
                                    "within_counter_button": selectedWindow && button.bounds.contains(button.convert(event.locationInWindow, from: nil)),
                                    "within_scroll": selectedWindow && scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
                                    "window_point": [event.locationInWindow.x, event.locationInWindow.y],
                                    "timestamp": event.timestamp]
        if let cg = event.cgEvent {
            entry["quartz_point"] = [cg.location.x, cg.location.y]
            entry["target_pid"] = cg.getIntegerValueField(.eventTargetUnixProcessID)
            entry["source_pid"] = cg.getIntegerValueField(.eventSourceUnixProcessID)
            entry["source_user_data"] = cg.getIntegerValueField(.eventSourceUserData)
            entry["quartz_unflipped_point"] = [cg.unflippedLocation.x, cg.unflippedLocation.y]
            entry["window_under_pointer"] = cg.getIntegerValueField(.mouseEventWindowUnderMousePointer)
            entry["window_can_handle"] = cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            entry["event_number"] = cg.getIntegerValueField(.mouseEventNumber)
            entry["click_state"] = cg.getIntegerValueField(.mouseEventClickState)
            entry["quartz_timestamp"] = cg.timestamp
        }
        if event.type == .scrollWheel {
            entry["scroll_delta_y"] = event.scrollingDeltaY
            entry["precise_scroll"] = event.hasPreciseScrollingDeltas
        }
        events.append(entry)
        if events.count > 128 { events.removeFirst(events.count - 128) }
        writeReport()
    }
    private func writeReport() {
        guard CommandLine.arguments.count == 2 else { return }
        let data = try? JSONSerialization.data(withJSONObject: ["text": field.stringValue, "clicks": clicks,
                         "window_number": window.windowNumber, "events": events,
                         "scroll_origin": [scroll.contentView.bounds.origin.x, scroll.contentView.bounds.origin.y]], options: [.sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
