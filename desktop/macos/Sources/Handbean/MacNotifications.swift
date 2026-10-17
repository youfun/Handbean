import AppKit
import Foundation
import HandbeanCore
import UserNotifications

/// Posts local notifications as this app, not as the BEAM child. A denied
/// permission stays denied for the launch; there is no AppleScript fallback.
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotifications()

    private var onOpen: ((String, String) -> Void)?
    private var pendingOpen: (String, String)?

    func install() {
        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationIfNeeded()
    }

    func setOpenHandler(_ handler: @escaping (String, String) -> Void) {
        onOpen = handler
        if let pendingOpen {
            self.pendingOpen = nil
            handler(pendingOpen.0, pendingOpen.1)
        }
    }

    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    ShellLog.write("notify authorization failed: \(error.localizedDescription)")
                } else if !granted {
                    ShellLog.write("notify authorization denied")
                }
            }
        }
    }

    func post(_ ended: NotifyEnded) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.enqueue(ended)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if granted {
                        self?.enqueue(ended)
                    } else if let error {
                        ShellLog.write("notify authorization failed: \(error.localizedDescription)")
                    }
                }
            default:
                break
            }
        }
    }

    func setBadge(running: Int, waiting: Int) {
        let label = NotifyProtocol.badgeCount(running: running, waiting: waiting).map(String.init)
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = label
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let conversationID = info["conversation_id"] as? String ?? ""
        let workspaceID = info["workspace_id"] as? String ?? ""
        if NotifyProtocol.validID(conversationID) {
            if let onOpen {
                onOpen(workspaceID, conversationID)
            } else {
                pendingOpen = (workspaceID, conversationID)
            }
        }
        completionHandler()
    }

    private func enqueue(_ ended: NotifyEnded) {
        let content = UNMutableNotificationContent()
        content.title = ended.title
        content.body = ended.body
        content.sound = .default
        content.threadIdentifier = ended.conversationID
        var info = [
            "conversation_id": ended.conversationID,
            "run_id": ended.runID,
        ]
        if let workspaceID = ended.workspaceID {
            info["workspace_id"] = workspaceID
        }
        content.userInfo = info
        let request = UNNotificationRequest(
            identifier: "handbean-ended-\(ended.conversationID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                ShellLog.write("notify post failed: \(error.localizedDescription)")
            }
        }
    }
}
