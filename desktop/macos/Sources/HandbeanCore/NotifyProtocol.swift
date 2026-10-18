import Foundation

public struct NotifyEnded: Equatable {
    public var reason: String
    public var title: String
    public var body: String
    public var conversationID: String
    public var workspaceID: String?
    public var runID: String

    public init(
        reason: String,
        title: String,
        body: String,
        conversationID: String,
        workspaceID: String?,
        runID: String
    ) {
        self.reason = reason
        self.title = title
        self.body = body
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.runID = runID
    }
}

public enum NotifyInbound: Equatable {
    case hello(token: String)
    case showEnded(NotifyEnded)
    case updateRunning(running: Int, waiting: Int)
}

/// Loopback messages between the spawned BEAM and the macOS app. The shell
/// rebuilds the conversation URL from validated ids; it does not open a path
/// supplied by the child.
public enum NotifyProtocol {
    public static let maxLineBytes = 8_192

    public static func parseLine(_ raw: String) -> NotifyInbound? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.utf8.count <= maxLineBytes,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String else { return nil }

        switch op {
        case "hello":
            guard let token = object["token"] as? String, tokensMatchShape(token) else { return nil }
            return .hello(token: token)
        case "show_ended":
            return parseEnded(object).map(NotifyInbound.showEnded)
        case "update_running":
            guard let running = count(object["running_count"]),
                  let waiting = count(object["waiting_count"]) else { return nil }
            return .updateRunning(running: running, waiting: waiting)
        default:
            return nil
        }
    }

    public static func tokensMatch(_ supplied: String, _ expected: String) -> Bool {
        let left = Array(supplied.utf8)
        let right = Array(expected.utf8)
        guard !left.isEmpty, left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0
    }

    public static func visibleData(_ visible: Bool) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: ["op": "visible", "value": visible]) else {
            return nil
        }
        data.append(10)
        return data
    }

    public static func conversationPath(workspaceID: String, conversationID: String) -> String? {
        guard validID(workspaceID), validID(conversationID) else { return nil }
        return "/w/\(workspaceID)/c/\(conversationID)"
    }

    public static func badgeCount(running: Int, waiting: Int) -> Int? {
        let total = running + waiting
        guard total > 0 else { return nil }
        return min(total, 999)
    }

    private static func parseEnded(_ object: [String: Any]) -> NotifyEnded? {
        guard let reason = object["reason"] as? String,
              reason == "completed" || reason == "failed",
              let title = clipped(object["title"], max: 120),
              let body = clipped(object["body"], max: 240),
              let conversationID = object["conversation_id"] as? String, validID(conversationID),
              let runID = object["run_id"] as? String, validID(runID) else { return nil }

        let workspaceID = (object["workspace_id"] as? String).flatMap { validID($0) ? $0 : nil }
        return NotifyEnded(
            reason: reason,
            title: title,
            body: body,
            conversationID: conversationID,
            workspaceID: workspaceID,
            runID: runID
        )
    }

    private static func tokensMatchShape(_ token: String) -> Bool {
        let count = token.utf8.count
        return (16...256).contains(count) && !token.contains(where: \.isNewline)
    }

    public static func validID(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double else { return nil }
        let int = number.intValue
        guard (0...999).contains(int) else { return nil }
        return int
    }

    private static func clipped(_ value: Any?, max: Int) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
