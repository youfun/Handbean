import Foundation

public struct AppOrigin: Equatable {
    public var hosts: Set<String>
    public var port: Int

    public init(hosts: Set<String>, port: Int) {
        self.hosts = Set(hosts.map { $0.lowercased() })
        self.port = port
    }

    public init(pageURL: URL, extraHosts: Set<String> = DesktopConfig.loopbackHosts) {
        var hosts = extraHosts
        if let host = pageURL.host {
            hosts.insert(host)
        }
        self.init(hosts: hosts, port: pageURL.port ?? 80)
    }
}

public enum NavigationDecision: Equatable {
    case allow
    case openExternally
    case cancel
}

public enum NavigationPolicy {
    /// Main-frame http(s) outside the Handbean origin opens in the system browser.
    /// Subframes outside that origin are cancelled so the shell cannot be steered
    /// into another site. LiveView preview is proxied on the same origin.
    public static func decide(url: URL, origin: AppOrigin, mainFrame: Bool) -> NavigationDecision {
        switch (url.scheme ?? "").lowercased() {
        case "about":
            return url.absoluteString == "about:blank" || url.host == nil ? .allow : .cancel
        case "http", "https":
            if isAppOrigin(url, origin) {
                return .allow
            }
            return mainFrame ? .openExternally : .cancel
        case "ws", "wss":
            return isAppOrigin(url, origin) ? .allow : .cancel
        case "mailto", "tel":
            return .openExternally
        default:
            return .cancel
        }
    }

    private static func isAppOrigin(_ url: URL, _ origin: AppOrigin) -> Bool {
        guard let host = url.host?.lowercased(), origin.hosts.contains(host) else { return false }
        let port = url.port ?? defaultPort(url.scheme)
        return port == origin.port
    }

    private static func defaultPort(_ scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https", "wss":
            return 443
        default:
            return 80
        }
    }
}
