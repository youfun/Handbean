import XCTest
@testable import HandbeanCore

final class NavigationPolicyTests: XCTestCase {
    private let origin = AppOrigin(pageURL: URL(string: "http://127.0.0.1:5008/")!)

    func testAllowsLiveViewOriginAndWebsocket() {
        XCTAssertEqual(decide("http://127.0.0.1:5008/"), .allow)
        XCTAssertEqual(decide("http://localhost:5008/settings"), .allow)
        XCTAssertEqual(decide("ws://127.0.0.1:5008/live/websocket"), .allow)
        XCTAssertEqual(decide("about:blank"), .allow)
    }

    func testMainFrameLeavesTheShell() {
        XCTAssertEqual(decide("https://github.com/youfun/Handbean"), .openExternally)
        XCTAssertEqual(decide("http://127.0.0.1:9/"), .openExternally)
        XCTAssertEqual(decide("mailto:dev@example.com"), .openExternally)
    }

    func testSubframeAndUnknownSchemesDoNotBrowse() {
        XCTAssertEqual(decide("https://evil.example/", mainFrame: false), .cancel)
        XCTAssertEqual(decide("file:///etc/passwd"), .cancel)
        XCTAssertEqual(decide("javascript:alert(1)"), .cancel)
        XCTAssertEqual(decide("ws://evil.example/socket"), .cancel)
    }

    func testMediaCaptureAllowsOnlyMicrophoneFromTheAppOrigin() {
        XCTAssertTrue(
            MediaCapturePolicy.allows(
                device: .microphone,
                host: "LOCALHOST",
                port: 5008,
                origin: origin
            )
        )
        XCTAssertFalse(
            MediaCapturePolicy.allows(
                device: .camera,
                host: "localhost",
                port: 5008,
                origin: origin
            )
        )
        XCTAssertFalse(
            MediaCapturePolicy.allows(
                device: .cameraAndMicrophone,
                host: "127.0.0.1",
                port: 5008,
                origin: origin
            )
        )
        XCTAssertFalse(
            MediaCapturePolicy.allows(
                device: .microphone,
                host: "evil.example",
                port: 5008,
                origin: origin
            )
        )
        XCTAssertFalse(
            MediaCapturePolicy.allows(
                device: .microphone,
                host: "localhost",
                port: 5009,
                origin: origin
            )
        )
    }

    private func decide(_ raw: String, mainFrame: Bool = true) -> NavigationDecision {
        NavigationPolicy.decide(url: URL(string: raw)!, origin: origin, mainFrame: mainFrame)
    }
}
