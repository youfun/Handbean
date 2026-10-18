public enum WorkspacePanelView: String, CaseIterable {
    case changes
    case files
    case browser
    case terminal

    public var title: String {
        switch self {
        case .changes: "Changes"
        case .files: "Files"
        case .browser: "Browser"
        case .terminal: "Terminal"
        }
    }
}

public struct WorkspacePanelToolbarLayout: Equatable {
    public let containerWidth: Double
    public let switcherWidth: Double

    public static func expanded(
        panelWidth: Double,
        panelRightInset: Double,
        panelLeadingInset: Double,
        toolbarTrailingInset: Double,
        iconWidth: Double,
        minimumGap: Double,
        preferredSwitcherWidth: Double,
        minimumSwitcherWidth: Double
    ) -> Self {
        let panelWidth = nonnegative(panelWidth)
        let panelRightInset = nonnegative(panelRightInset)
        let panelLeadingInset = nonnegative(panelLeadingInset)
        let toolbarTrailingInset = nonnegative(toolbarTrailingInset)
        let iconWidth = nonnegative(iconWidth)
        let minimumGap = nonnegative(minimumGap)
        let preferredSwitcherWidth = nonnegative(preferredSwitcherWidth)
        let minimumSwitcherWidth = min(
            nonnegative(minimumSwitcherWidth),
            preferredSwitcherWidth
        )
        let alignedWidth = max(
            0,
            panelWidth + panelRightInset - panelLeadingInset - toolbarTrailingInset
        )
        let minimumWidth = iconWidth + minimumGap + minimumSwitcherWidth
        let containerWidth = max(alignedWidth, minimumWidth)
        let availableSwitcherWidth = max(
            minimumSwitcherWidth,
            containerWidth - iconWidth - minimumGap
        )

        return Self(
            containerWidth: containerWidth,
            switcherWidth: min(preferredSwitcherWidth, availableSwitcherWidth)
        )
    }

    private static func nonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
