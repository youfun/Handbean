import Darwin
import Foundation

/// Captures the environment produced by the user's interactive login shell.
/// The helper writes JSON to an isolated pipe so shell startup output cannot
/// corrupt it. A valid environment wins even when a later rc command exits
/// non-zero.
public enum DesktopEnvironment {
    public static func capture(
        directory: String,
        inherited: [String: String],
        helper: String,
        timeout: TimeInterval = 3
    ) -> [String: String]? {
        guard let shell = loginShell(inherited: inherited) else { return nil }

        let process = Process()
        let environmentPipe = Pipe()
        let shellKind = ShellKind(path: shell)
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shellKind.arguments(
            command: shellKind.command(
                directory: directory,
                helper: helper
            )
        )
        process.environment = inherited
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardInput = shellKind.environmentDescriptor == .standardInput
            ? environmentPipe.fileHandleForWriting
            : FileHandle.nullDevice
        process.standardOutput = shellKind.environmentDescriptor == .standardOutput
            ? environmentPipe.fileHandleForWriting
            : FileHandle.nullDevice
        process.standardError = shellKind.environmentDescriptor == .standardError
            ? environmentPipe.fileHandleForWriting
            : FileHandle.nullDevice

        let capture = DataCapture(handle: environmentPipe.fileHandleForReading)
        capture.start()

        do {
            try process.run()
            environmentPipe.fileHandleForWriting.closeFile()
        } catch {
            environmentPipe.fileHandleForWriting.closeFile()
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        guard let data = capture.wait(timeout: 1) else { return nil }
        return decode(data)
    }

    public static func merged(
        inherited: [String: String],
        captured: [String: String]?
    ) -> [String: String] {
        guard let captured else { return inherited }
        var result = inherited
        for (key, value) in captured where key != "SHLVL" {
            result[key] = value
        }
        return result
    }

    public static func encoded(_ environment: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> [String: String]? {
        if let environment = decodeJSONObject(data) {
            return environment
        }

        let bytes = [UInt8](data)
        let starts = bytes.indices.filter { bytes[$0] == 0x7B }
        let ends = bytes.indices.filter { bytes[$0] == 0x7D }

        for start in starts {
            for end in ends.reversed() where end >= start {
                if let environment = decodeJSONObject(Data(bytes[start...end])) {
                    return environment
                }
            }
        }
        return nil
    }

    private static func decodeJSONObject(_ data: Data) -> [String: String]? {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let environment = value as? [String: String]
        else { return nil }
        return environment
    }

    private static func loginShell(inherited: [String: String]) -> String? {
        if let shell = inherited["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let record = getpwuid(getuid()), let raw = record.pointee.pw_shell {
            let shell = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: shell) {
                return shell
            }
        }
        return FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : nil
    }
}

private enum EnvironmentDescriptor {
    case standardInput
    case standardOutput
    case standardError
}

private enum ShellKind {
    case posix
    case rc
    case fish
    case nushell
    case tcsh
    case xonsh
    case powerShell

    init(path: String) {
        switch URL(fileURLWithPath: path).lastPathComponent.lowercased() {
        case "rc": self = .rc
        case "fish": self = .fish
        case "nu": self = .nushell
        case "csh", "tcsh": self = .tcsh
        case "xonsh": self = .xonsh
        case "pwsh", "powershell": self = .powerShell
        default: self = .posix
        }
    }

    var environmentDescriptor: EnvironmentDescriptor {
        switch self {
        case .nushell, .tcsh: return .standardOutput
        case .xonsh: return .standardError
        default: return .standardInput
        }
    }

    func arguments(command: String) -> [String] {
        switch self {
        case .nushell: return ["-l", "-e", command + "; exit"]
        default: return ["-l", "-i", "-c", command]
        }
    }

    func command(directory: String, helper: String) -> String {
        let cd = "cd \(quote(directory));"
        let prompt = self == .fish ? "emit fish_prompt;" : ""
        let executable = self == .nushell ? "^\(quote(helper))" : quote(helper)
        let redirection: String
        switch self {
        case .nushell, .tcsh: redirection = ""
        case .rc: redirection = ">[1=0]"
        case .xonsh: redirection = "o>e"
        case .powerShell: redirection = ">0"
        default: redirection = ">&0"
        }
        return "\(prompt)\(cd)\(executable) --printenv \(redirection)"
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class DataCapture: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data: Data?

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let captured = handle.readDataToEndOfFile()
            lock.lock()
            data = captured
            lock.unlock()
            group.leave()
        }
    }

    func wait(timeout: TimeInterval) -> Data? {
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
