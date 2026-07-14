import Foundation

enum CodexUsageFetcherError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex was not found. Install Codex and sign in first."
        case .launchFailed(let detail):
            return "Could not start Codex: \(detail)"
        case .timedOut:
            return "The Codex connection timed out. Try again later."
        case .serverError(let detail):
            return detail
        }
    }
}

final class CodexUsageFetcher {
    private let worker = DispatchQueue(label: "com.codexpulse.fetch", qos: .utility)

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        worker.async {
            let result = Result { try self.fetchSynchronously() }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func fetchSynchronously() throws -> UsageSnapshot {
        guard let executable = locateCodex() else {
            throw CodexUsageFetcherError.codexNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lock = NSLock()
        let completed = DispatchSemaphore(value: 0)
        var buffer = Data()
        var errorBuffer = Data()
        var responses: [Int: [String: Any]] = [:]
        var didSignal = false

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            var lines: [Data] = []
            lock.lock()
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            lock.unlock()

            for line in lines where !line.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let idNumber = object["id"] as? NSNumber else { continue }

                lock.lock()
                responses[idNumber.intValue] = object
                if responses[3] != nil, responses[4] != nil, !didSignal {
                    didSignal = true
                    completed.signal()
                }
                lock.unlock()
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            errorBuffer.append(data)
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexUsageFetcherError.launchFailed(error.localizedDescription)
        }

        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "codex-usage-float",
                        "title": "Codex Pulse",
                        "version": "1.0.2"
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false
                    ]
                ]
            ],
            ["method": "initialized"],
            ["method": "account/rateLimits/read", "id": 3],
            ["method": "account/usage/read", "id": 4]
        ]

        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        }

        guard completed.wait(timeout: .now() + 18) == .success else {
            lock.lock()
            let capturedError = errorBuffer
            lock.unlock()
            let detail = String(data: capturedError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let detail {
                let meaningfulLines = detail
                    .split(separator: "\n")
                    .filter { !$0.contains("PATH aliases") }
                    .joined(separator: "\n")
                if !meaningfulLines.isEmpty {
                    throw CodexUsageFetcherError.serverError(String(meaningfulLines.suffix(280)))
                }
            }
            throw CodexUsageFetcherError.timedOut
        }

        lock.lock()
        let captured = responses
        lock.unlock()

        if let error = captured[3]?["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw CodexUsageFetcherError.serverError(message)
        }

        return try UsageResponseParser.parse(responses: captured)
    }

    private func locateCodex() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let override = environment["CODEX_USAGE_CODEX_BIN"], !override.isEmpty {
            candidates.append(override)
        }

        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            NSString(string: "~/Applications/ChatGPT.app/Contents/Resources/codex").expandingTildeInPath,
            NSString(string: "~/Applications/Codex.app/Contents/Resources/codex").expandingTildeInPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
