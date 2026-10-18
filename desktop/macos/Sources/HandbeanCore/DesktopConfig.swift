import Darwin
import Foundation

/// Pure decisions for the macOS shell. The app process owns a backend only when
/// it spawned that process in this lifetime. A server that owns the packaged
/// database, or one selected with an explicit port, is attached to and never
/// signalled on quit.
public enum DesktopConfig {
    public static let defaultPort = 5008
    public static let bundleIdentifier = "com.youfun.handbean"
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
    public static let healthResponse = "handbean-desktop-health:v1"

    public static func healthURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/desktop-health")!
    }

    /// Parses `lsof -Fn` output and returns only IPv4/IPv6 loopback listeners.
    /// Other Beam listeners (for example Erlang distribution on all interfaces)
    /// must never become desktop attachment candidates.
    public static func loopbackListenerPorts(lsofOutput: String) -> [Int] {
        let ports = lsofOutput.split(whereSeparator: \.isNewline).compactMap { rawLine -> Int? in
            let line = String(rawLine)
            guard line.hasPrefix("n") else { return nil }

            let endpoint = String(line.dropFirst())
            let rawPort: Substring
            if endpoint.hasPrefix("127.0.0.1:") {
                rawPort = endpoint.dropFirst("127.0.0.1:".count)
            } else if endpoint.hasPrefix("[::1]:") {
                rawPort = endpoint.dropFirst("[::1]:".count)
            } else {
                return nil
            }

            guard let port = Int(rawPort), (1...65535).contains(port) else { return nil }
            return port
        }

        return Array(Set(ports)).sorted()
    }

    /// Spawned servers use 127.0.0.1 so the page host matches `PHX_HOST` and does
    /// not depend on `localhost` resolving to `::1`. An attached `./start.sh`
    /// defaults to `PHX_HOST=localhost`; a non-loopback discovered host is ignored.
    public static func pageURL(port: Int, spawnedByApp: Bool, discoveredHost: String?) -> URL {
        let host: String
        if spawnedByApp {
            host = "127.0.0.1"
        } else if let discovered = sanitizeHost(discoveredHost) {
            host = discovered
        } else {
            host = "localhost"
        }
        return URL(string: "http://\(host):\(port)/")!
    }

    public static func sanitizeHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard loopbackHosts.contains(host) else { return nil }
        return host
    }

    public static func hasExplicitPort(_ raw: String?) -> Bool {
        guard let raw, let port = Int(raw) else { return false }
        return (1...65535).contains(port)
    }

    /// The runtime holds an OS lock on a sidecar belonging to the resolved
    /// database path. Desktop discovery must use the same ownership boundary.
    public static func storageLockPath(databasePath: String) -> String {
        databasePath + ".lock"
    }

    public static func preferredPort(
        environment: String?,
        stored: String?,
        availablePort: () -> Int?
    ) -> Int {
        for raw in [environment, stored] {
            if let raw, let value = Int(raw), (1...65535).contains(value) {
                return value
            }
        }
        return availablePort() ?? defaultPort
    }

    /// Ask the kernel for an unused loopback port. The listener is closed before
    /// the backend starts, so callers must still handle the unlikely bind race.
    public static func availableLoopbackPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

public struct BackendLaunch: Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var pageURL: URL
}

public enum BackendPlanner {
    /// Never claim a listener we did not spawn. `ppid == 1` is not proof the
    /// desktop app started it: a manual `bin/handbean start` can be reparented too.
    public static func claimsExistingListener(command: String?, managedRoot: String?) -> Bool {
        _ = command
        _ = managedRoot
        return false
    }

    public static func launch(
        releaseRoot: String,
        port: Int,
        secret: String,
        databasePath: String,
        runtimeDir: String,
        inherited: [String: String]
    ) -> BackendLaunch {
        var env = inherited
        let overrides = [
            "PHX_SERVER": "true",
            "PORT": String(port),
            "PHX_HOST": "127.0.0.1",
            "DATABASE_PATH": databasePath,
            "SECRET_KEY_BASE": secret,
            "RELEASE_TMP": runtimeDir,
            "HANDBEAN_RUNTIME_DIR": runtimeDir,
            "HANDBEAN_FILE_MANAGER": "macos",
            "RELEASE_DISTRIBUTION": "none",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": inherited["LC_ALL"] ?? "en_US.UTF-8",
        ]
        for (key, value) in overrides {
            env[key] = value
        }
        let bin = (releaseRoot as NSString).appendingPathComponent("bin/handbean")
        return BackendLaunch(
            executable: "/bin/sh",
            arguments: [bin, "start"],
            environment: env,
            workingDirectory: releaseRoot,
            pageURL: DesktopConfig.pageURL(port: port, spawnedByApp: true, discoveredHost: nil)
        )
    }
}
