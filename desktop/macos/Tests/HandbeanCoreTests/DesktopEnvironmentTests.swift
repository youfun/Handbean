import XCTest
@testable import HandbeanCore

final class DesktopEnvironmentTests: XCTestCase {
    func testCapturesJSONFromAnIsolatedShellDescriptorInTheRequestedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handbean-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("print-env")
        try "#!/bin/sh\nprintf '{\"CAPTURED_CWD\":\"%s\",\"CAPTURE_MARKER\":\"%s\",\"PATH\":\"%s\"}' \"$PWD\" \"$CAPTURE_MARKER\" \"$PATH\"\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let environment = DesktopEnvironment.capture(
            directory: root.path,
            inherited: [
                "SHELL": "/bin/sh",
                "PATH": "/usr/bin:/bin",
                "CAPTURE_MARKER": "preserved",
            ],
            helper: helper.path
        )

        XCTAssertEqual(environment?["CAPTURED_CWD"], root.path)
        XCTAssertEqual(environment?["CAPTURE_MARKER"], "preserved")
        XCTAssertTrue(environment?["PATH"]?.contains("/usr/bin") == true)
    }

    func testEnvironmentJSONRoundTripsValues() throws {
        let environment = [
            "PATH": "/Users/me/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin",
            "MULTILINE": "first\nsecond",
        ]

        let data = try XCTUnwrap(DesktopEnvironment.encoded(environment))

        XCTAssertEqual(DesktopEnvironment.decode(data), environment)
    }

    func testEnvironmentJSONIsExtractedFromShellStartupNoise() {
        let data = Data("welcome from shell\n{\"PATH\":\"/usr/bin\",\"MARKER\":\"ok\"}logout\n".utf8)

        XCTAssertEqual(
            DesktopEnvironment.decode(data),
            ["PATH": "/usr/bin", "MARKER": "ok"]
        )
    }

    func testCapturedEnvironmentOverridesGUIEnvironmentExceptShellLevel() {
        let environment = DesktopEnvironment.merged(
            inherited: [
                "PATH": "/Applications/Handbean.app/Contents/Resources/handbean-web/bin:/usr/bin",
                "GUI_ONLY": "kept",
                "SHLVL": "1",
            ],
            captured: [
                "PATH": "/Users/me/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin",
                "PROJECT_TOOL": "available",
                "SHLVL": "2",
            ]
        )

        XCTAssertEqual(
            environment["PATH"],
            "/Users/me/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin"
        )
        XCTAssertEqual(environment["PROJECT_TOOL"], "available")
        XCTAssertEqual(environment["GUI_ONLY"], "kept")
        XCTAssertEqual(environment["SHLVL"], "1")
    }

    func testCaptureFailureKeepsInheritedEnvironment() {
        let inherited = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]

        XCTAssertEqual(
            DesktopEnvironment.merged(inherited: inherited, captured: nil),
            inherited
        )
    }
}
