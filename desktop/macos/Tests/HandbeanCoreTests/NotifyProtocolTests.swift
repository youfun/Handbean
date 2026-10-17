import XCTest
@testable import HandbeanCore

final class NotifyProtocolTests: XCTestCase {
    func testHelloAndRunningLines() {
        XCTAssertEqual(
            NotifyProtocol.parseLine(#"{"op":"hello","token":"0123456789abcdef"}"#),
            .hello(token: "0123456789abcdef")
        )
        XCTAssertEqual(
            NotifyProtocol.parseLine(#"{"op":"update_running","running_count":1,"waiting_count":2}"#),
            .updateRunning(running: 1, waiting: 2)
        )
        XCTAssertNil(NotifyProtocol.parseLine(#"{"op":"hello","token":"short"}"#))
        XCTAssertNil(NotifyProtocol.parseLine(#"{"op":"update_running","running_count":-1,"waiting_count":0}"#))
    }

    func testShowEndedRejectsCancelledAndUnsafeIDs() {
        let ended = NotifyProtocol.parseLine(
            #"{"op":"show_ended","reason":"completed","title":"Handbean","body":"Agent replied.","conversation_id":"conv_1","workspace_id":"ws-1","run_id":"run-1"}"#
        )
        XCTAssertEqual(
            ended,
            .showEnded(NotifyEnded(
                reason: "completed",
                title: "Handbean",
                body: "Agent replied.",
                conversationID: "conv_1",
                workspaceID: "ws-1",
                runID: "run-1"
            ))
        )
        XCTAssertNil(
            NotifyProtocol.parseLine(
                #"{"op":"show_ended","reason":"cancelled","title":"Handbean","body":"stopped","conversation_id":"conv","run_id":"run"}"#
            )
        )
        XCTAssertNil(NotifyProtocol.conversationPath(workspaceID: "../etc", conversationID: "conv"))
        XCTAssertEqual(NotifyProtocol.conversationPath(workspaceID: "ws-1", conversationID: "conv_1"), "/w/ws-1/c/conv_1")
    }

    func testTokenCompareRejectsDifferentLengths() {
        XCTAssertTrue(NotifyProtocol.tokensMatch("0123456789abcdef", "0123456789abcdef"))
        XCTAssertFalse(NotifyProtocol.tokensMatch("0123456789abcdef", "0123456789abcdee"))
        XCTAssertFalse(NotifyProtocol.tokensMatch("0123456789abcdef", "0123456789abcdef-extra"))
        XCTAssertFalse(NotifyProtocol.tokensMatch("", ""))
    }

    func testVisiblePayloadAndBadge() throws {
        let data = try XCTUnwrap(NotifyProtocol.visibleData(false))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["op"] as? String, "visible")
        XCTAssertEqual(object?["value"] as? Bool, false)
        XCTAssertEqual(NotifyProtocol.badgeCount(running: 0, waiting: 0), nil)
        XCTAssertEqual(NotifyProtocol.badgeCount(running: 2, waiting: 1), 3)
    }
}
