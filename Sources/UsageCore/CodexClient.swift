import Foundation

public enum CodexError: LocalizedError {
    case missingExecutable, disconnected, timeout, invalidResponse, service(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: return "Install Codex CLI or choose its location in Settings."
        case .disconnected: return "Codex stopped responding. Check that Codex can run, then refresh."
        case .timeout: return "Codex took too long to respond. Check your connection, then refresh."
        case .invalidResponse: return "This Codex version returned an unsupported response. Update Codex and refresh."
        case .service(let message): return message
        }
    }
}

public enum CodexExecutable {
    private static func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    public static func locate(customPath: String? = nil) -> String? {
        if let customPath, !customPath.isEmpty {
            return isExecutable(customPath) ? customPath : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirectories.map { $0 + "/codex" } + [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home + "/.local/bin/codex", home + "/.npm-global/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        return candidates.first { isExecutable($0) }
    }
}

/// Reads usage and consumes a selected reset only after explicit user confirmation.
/// Codex itself handles sign-in. Authentication files are never opened by this client.
public actor CodexClient: CodexUsageService {
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var connectedPath: String?

    public init() {}

    public func consumeReset(executablePath: String, creditID: String, idempotencyKey: String) async throws -> ResetOutcome {
        guard !creditID.isEmpty, !idempotencyKey.isEmpty else { throw CodexError.invalidResponse }
        do {
            if connectedPath != executablePath { shutdown() }
            if process == nil { try await connect(executablePath) }
            let data = try await request("account/rateLimitResetCredit/consume", params: [
                "creditId": creditID, "idempotencyKey": idempotencyKey
            ])
            return try JSONDecoder().decode(ResetResponse.self, from: data).outcome
        } catch {
            shutdown()
            throw error
        }
    }

    public func readLimits(executablePath: String) async throws -> UsageSnapshot {
        do {
            if connectedPath != executablePath { shutdown() }
            if process == nil { try await connect(executablePath) }
            let data = try await request("account/rateLimits/read")
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            shutdown()
            throw error
        }
    }

    private func connect(_ path: String) async throws {
        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        child.environment = environment
        try child.run()
        process = child
        input = stdinPipe.fileHandleForWriting
        connectedPath = path
        let currentGeneration = generation
        let output = stdoutPipe.fileHandleForReading
        reader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = output.availableData
                if data.isEmpty { break }
                await self?.receive(data, generation: currentGeneration)
            }
            try? output.close()
            await self?.didClose(generation: currentGeneration)
        }
        _ = try await request("initialize", params: [
            "clientInfo": ["name": "watch_the_limits", "title": "Watch the Limits", "version": "0.6.0"]
        ])
        try send(["method": "initialized"])
    }

    private func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timers[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                await self?.expire(id)
            }
            var message: [String: Any] = ["id": id, "method": method]
            if let params { message["params"] = params }
            do { try send(message) } catch { finish(id, result: .failure(error)) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CodexError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, generation token: UUID) {
        guard token == generation else { return }
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else { shutdown(); return }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int, pending[id] != nil else { continue }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Could not read usage. Sign in with codex login, then refresh."
                finish(id, result: .failure(CodexError.service(message)))
            } else if let result = object["result"],
                      let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                finish(id, result: .success(data))
            } else {
                finish(id, result: .failure(CodexError.invalidResponse))
            }
        }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func expire(_ id: Int) { finish(id, result: .failure(CodexError.timeout)) }

    private func didClose(generation token: UUID) {
        guard token == generation else { return }
        shutdown()
    }

    public func shutdown() {
        generation = UUID()
        reader?.cancel()
        reader = nil
        try? input?.close()
        input = nil
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        connectedPath = nil
        buffer.removeAll()
        for id in Array(pending.keys) { finish(id, result: .failure(CodexError.disconnected)) }
    }
}
