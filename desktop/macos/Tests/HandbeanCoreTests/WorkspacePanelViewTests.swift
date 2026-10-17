import XCTest
@testable import HandbeanCore

final class WorkspacePanelViewTests: XCTestCase {
    func testNativeSwitcherMatchesWebPanelOrder() {
        XCTAssertEqual(
            WorkspacePanelView.allCases.map(\.rawValue),
            ["changes", "files", "browser", "terminal"]
        )
        XCTAssertEqual(
            WorkspacePanelView.allCases.map(\.title),
            ["Changes", "Files", "Browser", "Terminal"]
        )
    }

    func testToolbarAlignsSwitcherWithPanelContentEdge() {
        let layout = WorkspacePanelToolbarLayout.expanded(
            panelWidth: 440,
            panelRightInset: 0,
            panelLeadingInset: 9,
            toolbarTrailingInset: 8,
            iconWidth: 82,
            minimumGap: 12,
            preferredSwitcherWidth: 316,
            minimumSwitcherWidth: 204
        )

        XCTAssertEqual(layout.containerWidth, 423)
        XCTAssertEqual(layout.switcherWidth, 316)
    }

    func testToolbarCompressesSwitcherInsideResponsivePanel() {
        let layout = WorkspacePanelToolbarLayout.expanded(
            panelWidth: 330,
            panelRightInset: 0,
            panelLeadingInset: 9,
            toolbarTrailingInset: 8,
            iconWidth: 82,
            minimumGap: 12,
            preferredSwitcherWidth: 316,
            minimumSwitcherWidth: 204
        )

        XCTAssertEqual(layout.containerWidth, 313)
        XCTAssertEqual(layout.switcherWidth, 219)
    }

    func testToolbarKeepsLabelsUsableWhenPanelIsTooNarrow() {
        let layout = WorkspacePanelToolbarLayout.expanded(
            panelWidth: 280,
            panelRightInset: 0,
            panelLeadingInset: 9,
            toolbarTrailingInset: 8,
            iconWidth: 82,
            minimumGap: 12,
            preferredSwitcherWidth: 316,
            minimumSwitcherWidth: 204
        )

        XCTAssertEqual(layout.containerWidth, 298)
        XCTAssertEqual(layout.switcherWidth, 204)
    }
}
