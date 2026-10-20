import AppKit
import ApplicationServices
import Dispatch
import HandbeanCore

/// MainActor serializes lease admission, target consent, cancellation and every
/// input unit. Awaited capture/consent must revalidate the generation before effects.
@MainActor
final class ComputerController: NSObject {
    static let fixtureAppID = "com.youfun.computerfixture"
    private let verificationOnly: Bool
    private var lease = ComputerLease()
    private var target: ComputerTarget?
    private var activeRequest: String?
    private var pointerEventNumber: Int64 = 0
    private var retired: [String: TimeInterval] = [:]
    private var panel: NSPanel?
    private var label: NSTextField?
    private var alert: NSAlert?
    private var consent: CheckedContinuation<Bool, Never>?

    enum Refusal: Error { case stopped, busy, invalidInput, stale, denied, deadline, unsupportedPointer }

    init(verificationOnly: Bool = false) {
        self.verificationOnly = verificationOnly
        super.init()
    }

    func perform(id: String, session: String, input: [String: Any], deadline: Double) async -> [String: Any] {
        let action = input["action"] as? String ?? ""
        if action == "status" {
            return ["screen_recording": CGPreflightScreenCaptureAccess(),
                    "accessibility": AXIsProcessTrusted(),
                    "event_post": CGPreflightPostEventAccess(),
                    "actions": ["list": true, "select": true, "observe": true,
                                "type": true, "key": true, "click": false, "scroll": false,
                                "stop": true],
                    "side_effect": "not_started"]
        }
        if action == "stop_all" {
            stop()
            return ["text": "Native control stopped", "side_effect": "not_started"]
        }
        if action == "stop" {
            stop(session: session)
            return ["text": "Native control stopped", "side_effect": "not_started"]
        }
        if action == "list" {
            let inventory = ComputerTarget.inventory().filter { !verificationOnly || $0["app_id"] as? String == Self.fixtureAppID }
            return ["windows": Array(inventory.prefix(100)),
                    "screen_recording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted(),
                    "event_post": CGPreflightPostEventAccess(),
                    "delivery_mode": "foreground_only", "side_effect": "not_started"]
        }
        guard activeRequest == nil else { return failure(Refusal.busy, dispatched: false) }
        activeRequest = id
        var dispatched = false
        defer { if activeRequest == id { activeRequest = nil } }
        do {
            retired = retired.filter { ProcessInfo.processInfo.systemUptime - $0.value < 120 }
            guard retired[session] == nil else { throw Refusal.stopped }
            let consentRequirement = ComputerConsentPolicy.requirement(for: action)
            if action == "select" {
                guard consentRequirement == .targetSelection else { throw Refusal.invalidInput }
                try lease.claim(session: session, now: ProcessInfo.processInfo.systemUptime)
                guard let appID = input["app_id"] as? String,
                      let number = input["window_id"] as? UInt32,
                      !verificationOnly || appID == Self.fixtureAppID else { throw Refusal.invalidInput }
                let selected = try ComputerTarget.select(appID: appID, windowID: number)
                let generation = lease.generation
                let detail = """
                Window \(number): \(selected.title)

                Until this Agent run ends, you press Stop, or no selected-window request is received for two minutes, Handbean may capture this exact window and send supported foreground keyboard input without asking again. Input can transmit data or change the selected app. Window screenshots may be sent to the selected model provider.

                Terminal, password and security apps, permission dialogs, and Handbean are forbidden. Click and scroll remain unavailable in normal applications until native pointer acceptance is complete.
                """
                guard await approve("Allow Computer Use in \(appID) for this task?", detail: detail) else { throw Refusal.denied }
                try check(session, generation, deadline)
                target = selected
                showControl("Controlling \(appID), window \(number)")
                return try await observe(selected, session: session, generation: generation, deadline: deadline, dispatched: false)
            }
            guard let target else { throw Refusal.stopped }
            guard action == "observe" || consentRequirement == .activeLease else { throw Refusal.invalidInput }
            let generation: UInt64
            do {
                generation = try lease.renew(session: session, now: ProcessInfo.processInfo.systemUptime)
            } catch {
                revokeAuthorization(session: session)
                throw error
            }
            try check(session, generation, deadline)
            if action == "observe" {
                return try await observe(target, session: session, generation: generation, deadline: deadline, dispatched: false)
            }
            let pointerAdmission = ComputerPointerAdmission.resolve(
                action: action,
                verificationOnly: verificationOnly,
                receiveProbe: input["pointer_probe"] as? Bool == true,
                controlAcceptance: input["pointer_acceptance"] as? Bool == true
            )
            switch pointerAdmission {
            case .unsupported:
                throw Refusal.unsupportedPointer
            case .invalid:
                throw Refusal.invalidInput
            default:
                break
            }
            guard let receipt = input["observation_id"] as? String else { throw Refusal.invalidInput }
            let snapshot = try lease.consume(receipt: receipt, rect: target.bounds(), now: ProcessInfo.processInfo.systemUptime)
            let units = try events(input, snapshot: snapshot, target: target)
            try check(session, generation, deadline)
            guard ProcessInfo.processInfo.systemUptime - snapshot.createdAt < 30,
                  try target.bounds() == snapshot.rect else { throw Refusal.stale }
            try await target.activate()
            try check(session, generation, deadline)
            for pair in units {
                try check(session, generation, deadline)
                guard try target.bounds() == snapshot.rect else { throw Refusal.stale }
                try target.checkFocus()
                // Synchronous AX checks can outlast the deadline; MainActor's
                // timeout task cannot run until they return. Recheck before down.
                try check(session, generation, deadline)
                // PID routing provides a second boundary if foreground changes
                // between checking focus and posting; never post to the HID tap.
                dispatched = true
                // Stamp at dispatch, after potentially long focus/activation checks.
                pair.0.timestamp = DispatchTime.now().uptimeNanoseconds
                pair.0.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.pid))
                // Public diagnostic tags ("HBPROB"/"HBCUA1"), not authorization.
                let tag: Int64 = pointerAdmission == .receiveProbe ? 0x484250524F42 : 0x484243554131
                pair.0.setIntegerValueField(.eventSourceUserData, value: tag)
                pair.0.postToPid(target.pid)
                if let up = pair.1 {
                    up.timestamp = DispatchTime.now().uptimeNanoseconds
                    up.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.pid))
                    up.setIntegerValueField(.eventSourceUserData, value: tag)
                    up.postToPid(target.pid)
                }
                await Task.yield()
            }
            return try await observe(target, session: session, generation: generation, deadline: deadline, dispatched: true)
        } catch {
            if action == "select" {
                stop(session: session)
            } else if invalidatesAuthorization(error) {
                revokeAuthorization(session: session)
            }
            return failure(error, dispatched: dispatched)
        }
    }

    func cancel(request: String) {
        if activeRequest == request { stop() }
    }
    func stop(session: String? = nil) {
        if let session { retired[session] = ProcessInfo.processInfo.systemUptime }
        else if let owner = lease.session { retired[owner] = ProcessInfo.processInfo.systemUptime }
        guard session == nil || lease.session == session else { return }
        if let alert { panel?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
        revokeAuthorization(session: session)
        finishConsent(false)
    }
    @objc private func stopClicked() { stop() }

    private func revokeAuthorization(session: String?) {
        guard ComputerConsentPolicy.mayClearAuthorization(
            requestedSession: session,
            leaseOwner: lease.session
        ) else { return }
        lease.stop(session: session)
        target = nil
        label?.stringValue = "Computer Use stopped"
        panel?.orderOut(nil)
    }

    private func invalidatesAuthorization(_ error: Error) -> Bool {
        guard let refusal = error as? ComputerTarget.Refusal else { return false }
        switch refusal {
        case .forbidden, .unavailable, .ambiguousWindow, .permission:
            return true
        case .focus, .dialog, .imageTooLarge:
            return false
        }
    }

    private func check(_ session: String, _ generation: UInt64, _ deadline: Double) throws {
        try Task.checkCancellation()
        guard lease.valid(
            session: session,
            generation: generation,
            now: ProcessInfo.processInfo.systemUptime
        ) else {
            revokeAuthorization(session: session)
            throw Refusal.stopped
        }
        guard Date().timeIntervalSince1970 * 1000 < deadline else { throw Refusal.deadline }
    }

    private func observe(_ target: ComputerTarget, session: String, generation: UInt64, deadline: Double, dispatched: Bool) async throws -> [String: Any] {
        let (image, data, rect) = try await target.capture()
        try check(session, generation, deadline)
        let receipt = lease.observe(rect: rect, pixels: CGSize(width: image.width, height: image.height), now: ProcessInfo.processInfo.systemUptime)
        return ["app_id": target.appID, "window_id": target.windowID, "observation_id": receipt,
                "width": image.width, "height": image.height, "coordinate_space": "window_image_pixels",
                "image": data.base64EncodedString(), "mime_type": "image/png",
                "side_effect": dispatched ? "unknown" : "not_started",
                "text": dispatched ? "Input dispatched without OS acknowledgement. Inspect this new observation; never blindly retry." : "Window observed. Receipt expires after 30 seconds and is consumed by one action."]
    }

    private func events(_ input: [String: Any], snapshot: ComputerLease.Observation, target: ComputerTarget) throws -> [(CGEvent, CGEvent?)] {
        let source = CGEventSource(stateID: .privateState)
        // CGEvent window-under-pointer fields alone did not associate NSEvent
        // with the receiving NSWindow. Use the public window-base constructor;
        // do not change its CG location (even a same-value setter loses local
        // annotation in native probes). Cross-process delivery remains a probe.
        func routePointer(_ event: CGEvent) {
            event.flags = []
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventNumber, value: pointerEventNumber)
        }
        func pointer(_ type: NSEvent.EventType, _ point: CGPoint) throws -> CGEvent {
            let local = CGPoint(x: point.x - snapshot.rect.minX, y: snapshot.rect.maxY - point.y)
            let click = type == .leftMouseDown || type == .leftMouseUp
            guard let native = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(target.windowID),
                      context: nil, eventNumber: Int(pointerEventNumber), clickCount: click ? 1 : 0,
                      pressure: type == .leftMouseDown ? 1 : 0),
                  let event = native.cgEvent else { throw Refusal.invalidInput }
            routePointer(event)
            return event
        }
        func keyboard(_ key: CGKeyCode, text: String? = nil) throws -> (CGEvent, CGEvent?) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { throw Refusal.invalidInput }
            if let text {
                let utf16 = Array(text.utf16)
                guard utf16.count <= 32 else { throw Refusal.invalidInput }
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            down.flags = []; up.flags = []
            return (down, up)
        }
        switch input["action"] as? String {
        case "click":
            guard let x = input["x"] as? Double, let y = input["y"] as? Double else { throw Refusal.invalidInput }
            let point = try snapshot.point(x: x, y: y)
            pointerEventNumber &+= 1
            return [(try pointer(.leftMouseDown, point), try pointer(.leftMouseUp, point))]
        case "type":
            guard let text = input["text"] as? String, !text.isEmpty, text.count <= 1000,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Refusal.invalidInput }
            return try text.map { try keyboard(0, text: String($0)) }
        case "key":
            let keys: [String: CGKeyCode] = ["return": 36, "tab": 48, "escape": 53, "left": 123, "right": 124, "up": 126, "down": 125, "backspace": 51]
            guard let name = input["key"] as? String, let key = keys[name] else { throw Refusal.invalidInput }
            return [try keyboard(key)]
        case "scroll":
            guard let delta = input["delta_y"] as? Int32, abs(Int64(delta)) <= 500,
                  let x = input["x"] as? Double, let y = input["y"] as? Double,
                  let template = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { throw Refusal.invalidInput }
            pointerEventNumber &+= 1
            let event = try pointer(.mouseMoved, snapshot.point(x: x, y: y))
            event.type = .scrollWheel
            // There is no public NSEvent scroll factory. Preserve the public
            // mouse factory's window annotation, copy only named scroll fields.
            let fields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
                .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase]
            for field in fields { event.setIntegerValueField(field, value: template.getIntegerValueField(field)) }
            return [(event, nil)]
        default: throw Refusal.invalidInput
        }
    }

    private func failure(_ error: Error, dispatched: Bool) -> [String: Any] {
        if let refusal = error as? Refusal, case .unsupportedPointer = refusal {
            return ["error": "unsupportedPointer", "side_effect": "not_started", "recovery": "none",
                    "text": "Public PID pointer delivery is not validated. Click/scroll are disabled except receive-and-suppress probes in the dedicated verification fixture. Do not retry."]
        }
        return ["error": String(describing: error), "side_effect": dispatched ? "unknown" : "not_started",
         "recovery": "observe", "text": "Refused or interrupted. Observe again before any further input. Do not retry a possible side effect."]
    }
    private func showControl(_ text: String) {
        if panel == nil {
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Handbean Computer Use"
            window.isFloatingPanel = true
            let label = NSTextField(wrappingLabelWithString: text)
            label.frame = CGRect(x: 20, y: 65, width: 460, height: 55)
            window.contentView?.addSubview(label)
            self.label = label
            let stop = NSButton(title: "Stop Computer Use", target: self, action: #selector(stopClicked))
            stop.frame = CGRect(x: 20, y: 15, width: 200, height: 35)
            window.contentView?.addSubview(stop)
            window.center()
            panel = window
        }
        label?.stringValue = text
        panel?.orderFrontRegardless()
    }
    private func approve(_ title: String, detail: String) async -> Bool {
        showControl(title)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow for this task")
        alert.addButton(withTitle: "Cancel")
        self.alert = alert
        NSApp.activate(ignoringOtherApps: true)
        guard let panel else { return false }
        return await withCheckedContinuation { continuation in
            consent = continuation
            alert.beginSheetModal(for: panel) { [weak self] response in
                self?.finishConsent(response == .alertFirstButtonReturn)
            }
        }
    }
    private func finishConsent(_ approved: Bool) {
        let waiting = consent
        consent = nil
        alert = nil
        waiting?.resume(returning: approved)
    }
}
