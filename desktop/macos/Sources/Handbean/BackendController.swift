import Darwin
import Foundation
import HandbeanCore
import Security

@MainActor
final class BackendController {
    enum State: Equatable {
        case idle
        case starting
        case ready(url: URL, owned: Bool)
        case failed(String)
    }

    private(set) var state: State = .idle
    var onChange: ((State) -> Void)?

    private var process: Process?
    private var computerBridge: ComputerBridge?
    private var notifyBridge: NotifyBridge?
    var appVisible: () -> Bool = { true }
    private var logHandle: FileHandle?
    private var intentionalStop = false
    private var startGeneration = 0
    private let managedPort: Int
    private let allowsConfiguredPortAttachment: Bool
    private var port: Int
    private let fileManager = FileManager.default

    init(port: Int? = nil) {
        let environmentPort = ProcessInfo.processInfo.environment["HANDBEAN_PORT"]
        let resolvedPort = port ?? Self.resolvePort()
        self.managedPort = resolvedPort
        self.allowsConfiguredPortAttachment = port != nil || DesktopConfig.hasExplicitPort(environmentPort)
        self.port = resolvedPort
    }

    func start() {
        startGeneration += 1
        let generation = startGeneration
        if process?.isRunning != true {
            port = managedPort
        }
        state = .starting
        onChange?(state)
        Task { await self.boot(generation: generation) }
    }

    /// SIGTERM the backend this process spawned, then SIGKILL if it is still alive.
    /// Does nothing when this launch only attached to an existing server.
    func stopOwnedBackend() {
        stopBridges()
        startGeneration += 1
        intentionalStop = true
        guard let process else {
            closeLog()
            return
        }
        guard process.isRunning else {
            self.process = nil
            closeLog()
            removePidFile()
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
        closeLog()
        removePidFile()
        ShellLog.write("stopped owned backend")
    }

    private func boot(generation: Int) async {
        if process?.isRunning == true {
            await publishReady(generation: generation, spawned: true)
            return
        }
        if let ownerPID = storageOwnerPID() {
            if let ownerPort = await discoverStorageOwnerServer(pid: ownerPID) {
                await attach(port: ownerPort, generation: generation, reason: "storage owner")
            } else {
                guard generation == startGeneration else { return }
                state = .failed("偵測到另一個 Handbean 正在使用會話資料，但其網頁服務尚未就緒。請稍後重試。")
                onChange?(state)
            }
            return
        }
        if allowsConfiguredPortAttachment, await probe() {
            await attach(port: port, generation: generation, reason: "explicitly configured port")
            return
        }
        guard generation == startGeneration else { return }
        do {
            try await spawn(generation: generation)
        } catch {
            guard generation == startGeneration else { return }
            state = .failed(error.localizedDescription)
            onChange?(state)
            return
        }
        await publishReady(generation: generation, spawned: true)
    }

    private func attach(port: Int, generation: Int, reason: String) async {
        guard generation == startGeneration else { return }
        self.port = port
        let host = discoverPhoenixHost()
        let url = DesktopConfig.pageURL(port: port, spawnedByApp: false, discoveredHost: host)
        ShellLog.write("attaching to \(reason) at \(url.absoluteString)")
        state = .ready(url: url, owned: false)
        onChange?(state)
    }

    private func publishReady(generation: Int, spawned: Bool) async {
        let becameReady = await waitForHTTP(generation: generation)
        guard generation == startGeneration else { return }
        if becameReady {
            if spawned && process?.isRunning != true {
                state = .failed("後端在就緒後隨即退出。日誌：\(logURL.path)\n\n\(logTail())")
                onChange?(state)
                return
            }
            let url = DesktopConfig.pageURL(port: port, spawnedByApp: spawned, discoveredHost: nil)
            state = .ready(url: url, owned: spawned)
            onChange?(state)
            return
        }
        let tail = logTail()
        let detail = tail.isEmpty ? "" : "\n\n\(tail)"
        state = .failed("本機服務沒有在 \(port) 就緒。日誌：\(logURL.path)\(detail)")
        onChange?(state)
    }

    private func spawn(generation: Int) async throws {
        let root = try locateReleaseRoot()
        let bin = root.appendingPathComponent("bin/handbean")
        guard fileManager.isExecutableFile(atPath: bin.path) else {
            throw ShellError.missingRelease
        }
        let support = try directories()
        try fileManager.createDirectory(at: support.runtime, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: support.database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: support.logs, withIntermediateDirectories: true)
        rotateLogIfNeeded()

        let secret = try resolveSecret(path: support.secret)
        let processEnvironment = ProcessInfo.processInfo.environment
        let helper = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let home = fileManager.homeDirectoryForCurrentUser.path
        let captured = await Task.detached(priority: .userInitiated) {
            DesktopEnvironment.capture(
                directory: home,
                inherited: processEnvironment,
                helper: helper
            )
        }.value
        guard generation == startGeneration else { return }
        var inherited = DesktopEnvironment.merged(inherited: processEnvironment, captured: captured)
        inherited["HANDBEAN_DESKTOP_ENV_HELPER"] = helper
        let database = processEnvironment["DATABASE_PATH"] ?? support.database.path
        let launch = BackendPlanner.launch(
            releaseRoot: root.path,
            port: port,
            secret: secret,
            databasePath: database,
            runtimeDir: support.runtime.path,
            inherited: inherited
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        let bridge = try ComputerBridge()
        computerBridge = bridge
        let computerEnvironment: [String: String]
        do { computerEnvironment = try await bridge.start() }
        catch {
            stopBridges()
            throw error
        }
        guard generation == startGeneration, self.process?.isRunning != true else {
            stopBridges()
            return
        }
        let notifyEnvironment = await startNotifyBridge()
        guard generation == startGeneration, self.process?.isRunning != true else {
            stopBridges()
            return
        }
        let handle: FileHandle
        do { handle = try openLog() }
        catch {
            stopBridges()
            throw error
        }
        process.environment = launch.environment
            .merging(computerEnvironment) { _, computer in computer }
            .merging(notifyEnvironment) { _, notify in notify }
        process.currentDirectoryURL = URL(fileURLWithPath: launch.workingDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        let errorFD = dup(handle.fileDescriptor)
        process.standardError = errorFD >= 0 ? FileHandle(fileDescriptor: errorFD, closeOnDealloc: true) : handle
        process.qualityOfService = .userInitiated
        intentionalStop = false
        process.terminationHandler = { [weak self] exited in
            let code = exited.terminationStatus
            Task { @MainActor in
                self?.noteExit(code: code)
            }
        }
        do {
            try process.run()
        } catch {
            stopBridges()
            try? handle.close()
            if let stderr = process.standardError as? FileHandle, stderr !== handle { try? stderr.close() }
            throw ShellError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.logHandle = handle
        writePidFile(pid: process.processIdentifier, root: root.path)
        ShellLog.write("spawned backend pid \(process.processIdentifier) port \(port)")
    }

    private func noteExit(code: Int32) {
        stopBridges()
        let intentional = intentionalStop
        process = nil
        closeLog()
        removePidFile()
        guard !intentional else { return }
        if case .failed = state { return }
        state = .failed("後端已退出（狀態 \(code)）。日誌：\(logURL.path)")
        onChange?(state)
    }

    func stopComputerUse() { computerBridge?.controller.stop() }

    func noteAppVisibility(_ visible: Bool) {
        notifyBridge?.setVisible(visible)
    }

    private func startNotifyBridge() async -> [String: String] {
        do {
            let bridge = try NotifyBridge()
            bridge.currentVisibility = { [weak self] in
                self?.appVisible() ?? true
            }
            let environment = try await bridge.start()
            notifyBridge = bridge
            bridge.setVisible(appVisible())
            return environment
        } catch {
            ShellLog.write("system notifications unavailable")
            return [:]
        }
    }

    private func stopBridges() {
        computerBridge?.stop()
        computerBridge = nil
        notifyBridge?.stop()
        notifyBridge = nil
    }

    private func probe(port: Int? = nil, timeout: TimeInterval = 3) async -> Bool {
        let candidatePort = port ?? self.port
        var request = URLRequest(
            url: DesktopConfig.healthURL(port: candidatePort),
            timeoutInterval: timeout
        )
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            return String(data: data, encoding: .utf8) == DesktopConfig.healthResponse
        } catch {
            return false
        }
    }

    private func storageOwnerPID() -> String? {
        let defaultDatabase = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".handbean/handbean.db").path
        let database = ProcessInfo.processInfo.environment["DATABASE_PATH"] ?? defaultDatabase
        let lockPath = DesktopConfig.storageLockPath(databasePath: database)
        let ownerOutput = runTool("/usr/sbin/lsof", ["-nP", "-t", lockPath])
        return ownerOutput.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private func discoverStorageOwnerServer(pid ownerPID: String) async -> Int? {
        let listenerOutput = runTool(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-p", ownerPID, "-iTCP", "-sTCP:LISTEN", "-Fn"]
        )
        let candidates = DesktopConfig.loopbackListenerPorts(lsofOutput: listenerOutput)
        var declaredPort: Int?

        if let pid = Int32(ownerPID),
           let rawPort = environmentValue(pid: pid, key: "PORT"),
           let port = Int(rawPort),
           candidates.contains(port) {
            declaredPort = port
            for attempt in 0..<3 {
                if await probe(port: port, timeout: 5) {
                    return port
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        let fallbackCandidates = candidates.filter { $0 != declaredPort }
        for attempt in 0..<3 {
            if let port = await firstHandbeanServer(in: fallbackCandidates) {
                return port
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return nil
    }

    private func firstHandbeanServer(in candidates: [Int]) async -> Int? {
        return await withTaskGroup(of: Int?.self) { group in
            for candidatePort in candidates {
                group.addTask { [weak self] in
                    guard let self, await self.probe(port: candidatePort) else { return nil }
                    return candidatePort
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private func waitForHTTP(generation: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if generation != startGeneration { return false }
            if let process, !process.isRunning { return false }
            if await probe() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func discoverPhoenixHost() -> String? {
        guard let pid = listenerPID() else { return nil }
        return environmentValue(pid: pid, key: "PHX_HOST")
    }

    private func listenerPID() -> Int32? {
        let output = runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    private func environmentValue(pid: Int32, key: String) -> String? {
        let output = runTool("/bin/ps", ["eww", "-p", String(pid)])
        let prefix = "\(key)="
        for token in output.split(whereSeparator: \.isWhitespace) {
            let text = String(token)
            guard text.hasPrefix(prefix) else { continue }
            return String(text.dropFirst(prefix.count))
        }
        return nil
    }

    private func runTool(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func locateReleaseRoot() throws -> URL {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["HANDBEAN_WEB_ROOT"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("handbean-web") {
            candidates.append(resource)
        }
        candidates.append(appSupportURL().appendingPathComponent("handbean-web"))
        for candidate in candidates {
            let bin = candidate.appendingPathComponent("bin/handbean")
            if fileManager.isExecutableFile(atPath: bin.path) {
                return candidate.standardizedFileURL
            }
        }
        throw ShellError.missingRelease
    }

    private func resolveSecret(path: URL) throws -> String {
        if let env = ProcessInfo.processInfo.environment["SECRET_KEY_BASE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           env.count >= 32 {
            return env
        }
        return try LocalSecret.loadOrCreate(at: path)
    }

    private func directories() throws -> (runtime: URL, database: URL, secret: URL, logs: URL) {
        let home = fileManager.homeDirectoryForCurrentUser
        let handbean = home.appendingPathComponent(".handbean")
        let logs = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Logs/Handbean", isDirectory: true)
        return (
            handbean.appendingPathComponent("runtime", isDirectory: true),
            handbean.appendingPathComponent("handbean.db"),
            handbean.appendingPathComponent("secret_key_base"),
            logs
        )
    }

    private var logURL: URL {
        let logs = (try? fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return logs.appendingPathComponent("Logs/Handbean/backend.log")
    }

    private var pidURL: URL {
        appSupportURL().appendingPathComponent("backend.pid")
    }

    private func appSupportURL() -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Handbean", isDirectory: true)
    }

    private func openLog() throws -> FileHandle {
        let url = logURL
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func rotateLogIfNeeded() {
        let url = logURL
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber,
              number.intValue > 2_000_000
        else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: url, to: rotated)
    }

    private func logTail(maxLines: Int = 30) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text.split(whereSeparator: \.isNewline).suffix(maxLines).joined(separator: "\n")
    }

    private func writePidFile(pid: Int32, root: String) {
        let url = pidURL
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = "\(pid)\n\(root)\n\(port)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? fileManager.removeItem(at: pidURL)
    }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private static func resolvePort() -> Int {
        let env = ProcessInfo.processInfo.environment["HANDBEAN_PORT"]
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: "HandbeanPort")
        let port = DesktopConfig.preferredPort(
            environment: env,
            stored: stored,
            availablePort: DesktopConfig.availableLoopbackPort
        )
        if env == nil {
            defaults.set(String(port), forKey: "HandbeanPort")
        }
        return port
    }
}

enum ShellError: LocalizedError {
    case missingRelease
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRelease:
            return """
            找不到捆綁的 Handbean Web 後端。
            在 desktop/macos 執行 scripts/fetch_web_release.sh，或設定 HANDBEAN_WEB_ROOT。
            若已手動執行 ./start.sh，確認 http://127.0.0.1:5008 可連後再打開本 App。
            """
        case .launchFailed(let detail):
            return "無法啟動後端：\(detail)"
        }
    }
}

enum LocalSecret {
    static func loadOrCreate(at url: URL) throws -> String {
        if let existing = read(url), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let value = Data(bytes).base64EncodedString()
        try write(value, to: url)
        return value
    }

    private static func read(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return trimmed
    }

    private static func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ShellLog {
    static func write(_ message: String) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Handbean")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shell.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
