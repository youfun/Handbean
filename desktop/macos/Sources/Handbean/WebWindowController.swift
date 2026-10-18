import AppKit
import WebKit
import HandbeanCore

@MainActor
final class WebWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    private let webView: WKWebView
    private let overlay = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "重試", target: nil, action: nil)
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let panelButton = NSButton()
    private let workspaceSwitcher = WorkspacePanelSwitcher()
    private let actionsContainer = WorkspaceActionsBar()
    private let iconStack = NSStackView()
    private let workspaceActionsGap: CGFloat = 12
    private var actionsGapConstraint: NSLayoutConstraint?
    private var switcherWidthConstraint: NSLayoutConstraint?
    private var actionsInstalled = false
    private var measuredPanelWidth: CGFloat = 0
    private var measuredPanelRightInset: CGFloat = 0
    private var measuredPanelLeadingInset: CGFloat = 9
    private var measuredToolbarTrailingInset: CGFloat = 8
    private var panelSyncToken = 0
    private var origin = AppOrigin(hosts: DesktopConfig.loopbackHosts, port: DesktopConfig.defaultPort)
    private var loadedURL: URL?
    private var lastState: BackendController.State = .idle
    private var pendingConversation: (String, String)?
    var onRetry: (() -> Void)?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Handbean"
        window.minSize = NSSize(width: 960, height: 640)
        window.setFrameAutosaveName("HandbeanMain")
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        super.init(window: window)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        installToolbar()
        installViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showConversation(workspaceID: String, conversationID: String) {
        show()
        pendingConversation = (workspaceID, conversationID)
        loadPendingConversation()
    }

    private func loadPendingConversation() {
        guard let pending = pendingConversation else { return }
        guard let path = NotifyProtocol.conversationPath(
            workspaceID: pending.0,
            conversationID: pending.1
        ) else {
            pendingConversation = nil
            return
        }
        guard case .ready(let base, _) = lastState,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url,
              NavigationPolicy.decide(url: url, origin: origin, mainFrame: true) == .allow else {
            pendingConversation = nil
            return
        }
        pendingConversation = nil
        loadedURL = url
        hideOverlay()
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    func apply(_ state: BackendController.State) {
        lastState = state
        switch state {
        case .idle, .starting:
            showOverlay("正在啟動 Handbean…", retry: false)
        case .ready(let url, _):
            origin = AppOrigin(pageURL: url)
            window?.title = "Handbean"
            if pendingConversation != nil {
                loadPendingConversation()
            }
            if loadedURL == nil {
                loadedURL = url
                showOverlay("正在載入工作區…", retry: false)
                webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
            }
        case .failed(let message):
            showOverlay(message, retry: true)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch NavigationPolicy.decide(url: url, origin: origin, mainFrame: mainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            openExternally(url)
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            let decision = NavigationPolicy.decide(url: url, origin: origin, mainFrame: true)
            if decision == .openExternally {
                openExternally(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        showOverlay("頁面載入失敗：\(nsError.localizedDescription)", retry: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
        document.documentElement.classList.add('handbean-desktop-shell');
        if (!document.querySelector('#handbean-desktop-shell-style')) {
          const style = document.createElement('style');
          style.id = 'handbean-desktop-shell-style';
          style.textContent = '.workspace-panel-header, .workspace-panel-toggle { display: none !important; }';
          document.head.appendChild(style);
        }
        """)
        updateNavigationButtons()
        syncWorkspacePanelState()
        hideOverlay()
    }

    @objc private func goBack() {
        webView.goBack()
        updateNavigationButtons()
    }

    @objc private func goForward() {
        webView.goForward()
        updateNavigationButtons()
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func newConversation() {
        clickWebControl(".workspace-title-row.is-active .workspace-add-btn")
    }

    @objc private func toggleWorkspacePanel() {
        clickWebControl("[data-workspace-panel-toggle]")
        workspaceSwitcher.isHidden.toggle()
        updatePanelButton(collapsed: workspaceSwitcher.isHidden)
        layoutWorkspaceActions()
        syncWorkspacePanelState(after: 0.15)
    }

    @objc private func selectWorkspacePanelView() {
        let views = WorkspacePanelView.allCases
        guard views.indices.contains(workspaceSwitcher.selectedSegment) else { return }
        let view = views[workspaceSwitcher.selectedSegment].rawValue
        clickWebControl(
            "button[phx-click='select_right_panel_view'][phx-value-view='\(view)']"
        )
        syncWorkspacePanelState(after: 0.15)
    }

    @objc private func openSettings() {
        navigateWebControl("#open-settings")
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func retry() {
        if loadedURL != nil, case .ready = lastState {
            hideOverlay()
            webView.reload()
            return
        }
        onRetry?()
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "HandbeanToolbar.v2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .reload, .flexibleSpace, .primaryActions]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navigation, .reload, .flexibleSpace, .primaryActions]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation:
            configureToolbarButton(backButton, symbol: "chevron.left", action: #selector(goBack), help: "返回")
            configureToolbarButton(forwardButton, symbol: "chevron.right", action: #selector(goForward), help: "前進")
            updateNavigationButtons()
            let stack = NSStackView(views: [backButton, forwardButton])
            stack.orientation = .horizontal
            stack.spacing = 2
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = stack
            item.label = "導覽"
            return item
        case .reload:
            let button = NSButton()
            configureToolbarButton(button, symbol: "arrow.clockwise", action: #selector(reloadPage), help: "重新載入")
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = button
            item.label = "重新載入"
            return item
        case .primaryActions:
            let newButton = NSButton()
            configureToolbarButton(newButton, symbol: "plus", action: #selector(newConversation), help: "新對話")
            configureToolbarButton(
                panelButton,
                symbol: "sidebar.right",
                action: #selector(toggleWorkspacePanel),
                help: "切換工作區面板"
            )
            let settingsButton = NSButton()
            configureToolbarButton(settingsButton, symbol: "gearshape", action: #selector(openSettings), help: "設定")
            for button in [newButton, panelButton, settingsButton] {
                pinCompactToolbarButton(button)
            }
            iconStack.orientation = .horizontal
            iconStack.alignment = .centerY
            iconStack.spacing = 2
            iconStack.setViews([newButton, panelButton, settingsButton], in: .trailing)
            workspaceSwitcher.onSelect = { [weak self] in
                self?.selectWorkspacePanelView()
            }
            installActionsContainer()
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = actionsContainer
            item.label = "動作"
            layoutWorkspaceActions()
            return item
        default:
            return nil
        }
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        help: String
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.target = self
        button.action = action
        button.isBordered = false
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    private func pinCompactToolbarButton(_ button: NSButton) {
        guard button.constraints.isEmpty else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let image = button.image?.withSymbolConfiguration(config) {
            button.image = image
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imageScaling = .scaleProportionallyDown
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func installActionsContainer() {
        guard !actionsInstalled else { return }
        actionsInstalled = true
        workspaceSwitcher.translatesAutoresizingMaskIntoConstraints = false
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        actionsContainer.addSubview(workspaceSwitcher)
        actionsContainer.addSubview(iconStack)
        let gap = iconStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: workspaceSwitcher.trailingAnchor,
            constant: workspaceActionsGap
        )
        actionsGapConstraint = gap
        let switcherWidth = workspaceSwitcher.widthAnchor.constraint(
            equalToConstant: workspaceSwitcher.intrinsicContentSize.width
        )
        switcherWidthConstraint = switcherWidth
        actionsContainer.translatesAutoresizingMaskIntoConstraints = false
        actionsContainer.setContentHuggingPriority(.required, for: .horizontal)
        actionsContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            workspaceSwitcher.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor),
            workspaceSwitcher.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
            workspaceSwitcher.heightAnchor.constraint(equalToConstant: 22),
            iconStack.trailingAnchor.constraint(equalTo: actionsContainer.trailingAnchor),
            iconStack.centerYAnchor.constraint(equalTo: actionsContainer.centerYAnchor),
            gap,
            switcherWidth,
        ])
    }

    private func layoutWorkspaceActions() {
        guard actionsInstalled else { return }
        let collapsed = workspaceSwitcher.isHidden
        let iconWidth = iconStack.fittingSize.width

        if collapsed {
            switcherWidthConstraint?.constant = 0
            actionsGapConstraint?.constant = 0
            actionsContainer.measuredSize = NSSize(width: max(iconWidth, 1), height: 22)
            return
        }

        updateToolbarTrailingInset()
        let layout = WorkspacePanelToolbarLayout.expanded(
            panelWidth: Double(measuredPanelWidth),
            panelRightInset: Double(measuredPanelRightInset),
            panelLeadingInset: Double(measuredPanelLeadingInset),
            toolbarTrailingInset: Double(measuredToolbarTrailingInset),
            iconWidth: Double(iconWidth),
            minimumGap: Double(workspaceActionsGap),
            preferredSwitcherWidth: Double(workspaceSwitcher.intrinsicContentSize.width),
            minimumSwitcherWidth: Double(workspaceSwitcher.minimumContentWidth)
        )
        switcherWidthConstraint?.constant = CGFloat(layout.switcherWidth)
        actionsGapConstraint?.constant = workspaceActionsGap
        actionsContainer.measuredSize = NSSize(
            width: max(CGFloat(layout.containerWidth), 1),
            height: 22
        )
    }

    private func updateToolbarTrailingInset() {
        guard actionsContainer.window != nil, actionsContainer.bounds.width > 0 else { return }
        actionsContainer.superview?.layoutSubtreeIfNeeded()
        let webRight = webView.convert(webView.bounds, to: nil).maxX
        let actionsRight = actionsContainer.convert(actionsContainer.bounds, to: nil).maxX
        let candidate = webRight - actionsRight
        guard candidate.isFinite, (0...64).contains(candidate) else { return }
        measuredToolbarTrailingInset = candidate
    }

    private func clickWebControl(_ selector: String) {
        let encoded = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed)
        guard let encoded, let literal = String(data: encoded, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.querySelector(\(literal))?.click()")
    }

    private func navigateWebControl(_ selector: String) {
        let encoded = try? JSONSerialization.data(withJSONObject: selector, options: .fragmentsAllowed)
        guard let encoded, let literal = String(data: encoded, encoding: .utf8) else { return }
        webView.evaluateJavaScript("""
        (() => {
          const href = document.querySelector(\(literal))?.href;
          if (href) window.location.assign(href);
        })()
        """)
    }

    @objc private func contentFrameDidChange() {
        syncWorkspacePanelState(after: 0.08)
    }

    private func syncWorkspacePanelState(after delay: TimeInterval = 0) {
        panelSyncToken += 1
        let token = panelSyncToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.panelSyncToken == token else { return }
            let script = """
            (() => {
              const panel = document.querySelector('#workspace-panel');
              const toggle = document.querySelector('[data-workspace-panel-toggle]');
              if (!panel || !toggle) return null;
              const rect = panel.getBoundingClientRect();
              const header = panel.querySelector('.workspace-panel-header');
              const headerStyle = header ? getComputedStyle(header) : null;
              return {
                collapsed: toggle.getAttribute('aria-pressed') === 'false',
                view: document.querySelector('.workspace-panel-tab.active')?.getAttribute('phx-value-view') || '',
                browser: Boolean(document.querySelector("button[phx-value-view='browser']")),
                terminal: Boolean(document.querySelector("button[phx-value-view='terminal']")),
                width: rect.width,
                rightInset: Math.max(0, document.documentElement.clientWidth - rect.right),
                leadingInset: panel.clientLeft + (parseFloat(headerStyle?.paddingLeft) || 0)
              };
            })()
            """
            self.webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, self.panelSyncToken == token else { return }
                guard let state = result as? [String: Any] else {
                    self.panelButton.isEnabled = false
                    self.workspaceSwitcher.isHidden = true
                    self.measuredPanelWidth = 0
                    self.measuredPanelRightInset = 0
                    self.layoutWorkspaceActions()
                    return
                }
                let collapsed = state["collapsed"] as? Bool ?? false
                self.panelButton.isEnabled = true
                self.workspaceSwitcher.isHidden = collapsed
                self.updatePanelButton(collapsed: collapsed)
                self.workspaceSwitcher.setEnabled(
                    state["browser"] as? Bool ?? false,
                    forSegment: WorkspacePanelView.allCases.firstIndex(of: .browser) ?? -1
                )
                self.workspaceSwitcher.setEnabled(
                    state["terminal"] as? Bool ?? false,
                    forSegment: WorkspacePanelView.allCases.firstIndex(of: .terminal) ?? -1
                )
                self.workspaceSwitcher.selectedSegment = WorkspacePanelView.allCases.firstIndex {
                    $0.rawValue == (state["view"] as? String ?? "")
                } ?? -1
                let width = (state["width"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                let rightInset = (state["rightInset"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
                let leadingInset = (state["leadingInset"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 9
                self.measuredPanelWidth = collapsed ? 0 : width
                self.measuredPanelRightInset = collapsed ? 0 : rightInset
                self.measuredPanelLeadingInset = max(0, leadingInset)
                self.layoutWorkspaceActions()
            }
        }
    }

    private func updatePanelButton(collapsed: Bool) {
        panelButton.image = NSImage(
            systemSymbolName: "sidebar.right",
            accessibilityDescription: collapsed ? "顯示工作區面板" : "收起工作區面板"
        )
        panelButton.toolTip = collapsed ? "顯示工作區面板" : "收起工作區面板"
        panelButton.setAccessibilityLabel(panelButton.toolTip)
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func installViews() {
        guard let content = window?.contentView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        overlay.addSubview(statusLabel)
        overlay.addSubview(retryButton)
        content.addSubview(webView)
        content.addSubview(overlay)
        webView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: webView
        )
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -48),
            retryButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
        ])
    }

    private func showOverlay(_ message: String, retry: Bool) {
        statusLabel.stringValue = message
        retryButton.isHidden = !retry
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        overlay.isHidden = false
    }

    private func hideOverlay() {
        overlay.isHidden = true
    }
}

private extension NSToolbarItem.Identifier {
    static let navigation = NSToolbarItem.Identifier("HandbeanNavigation")
    static let reload = NSToolbarItem.Identifier("HandbeanReload")
    static let primaryActions = NSToolbarItem.Identifier("HandbeanPrimaryActions")
}

private final class WorkspaceActionsBar: NSView {
    var measuredSize = NSSize(width: 1, height: 22) {
        didSet {
            if oldValue != measuredSize { invalidateIntrinsicContentSize() }
        }
    }

    override var intrinsicContentSize: NSSize { measuredSize }
}

private final class WorkspacePanelSwitcher: NSView {
    var onSelect: (() -> Void)?
    var selectedSegment = 1 {
        didSet {
            if oldValue != selectedSegment { needsDisplay = true }
        }
    }

    private let labels = WorkspacePanelView.allCases.map(\.title)
    private var enabledSegments = Array(
        repeating: true,
        count: WorkspacePanelView.allCases.count
    )
    private let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    var minimumContentWidth: CGFloat {
        minimumSegmentWidth * CGFloat(labels.count)
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredSegmentWidth * CGFloat(labels.count), height: 22)
    }

    func setEnabled(_ enabled: Bool, forSegment index: Int) {
        guard enabledSegments.indices.contains(index), enabledSegments[index] != enabled else { return }
        enabledSegments[index] = enabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.45).setFill()
        track.fill()
        NSColor.separatorColor.setStroke()
        track.lineWidth = 1
        track.stroke()

        if labels.indices.contains(selectedSegment), enabledSegments[selectedSegment] {
            let pill = NSBezierPath(
                roundedRect: segmentRect(selectedSegment).insetBy(dx: 2, dy: 2),
                xRadius: 4,
                yRadius: 4
            )
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            pill.fill()
        }

        for (index, label) in labels.enumerated() {
            let font = index == selectedSegment
                ? NSFont.systemFont(ofSize: 12, weight: .semibold)
                : labelFont
            let color: NSColor = if !enabledSegments[index] {
                .disabledControlTextColor
            } else if index == selectedSegment {
                .labelColor
            } else {
                .secondaryLabelColor
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            let rect = segmentRect(index)
            let textRect = NSRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            (label as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let index = Int(convert(event.locationInWindow, from: nil).x / segmentWidth)
        guard labels.indices.contains(index), enabledSegments[index] else { return }
        selectedSegment = index
        onSelect?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }

    override func accessibilityLabel() -> String? { "工作區面板" }

    private var preferredSegmentWidth: CGFloat {
        ceil(max(longestLabelWidth + 28, 68))
    }

    private var minimumSegmentWidth: CGFloat {
        ceil(longestLabelWidth + 4)
    }

    private var longestLabelWidth: CGFloat {
        labels.map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 48
    }

    private var segmentWidth: CGFloat {
        guard !labels.isEmpty, bounds.width > 0 else { return preferredSegmentWidth }
        return bounds.width / CGFloat(labels.count)
    }

    private func segmentRect(_ index: Int) -> NSRect {
        NSRect(x: segmentWidth * CGFloat(index), y: 0, width: segmentWidth, height: bounds.height)
    }
}
