import Darwin
import Foundation

private final class SelfTestBox<Value> {
    private let lock = NSLock()
    private var storedValue: Value?

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

enum SelfTest {
    static func run() -> Bool {
        let responses: [Int: [String: Any]] = [
            3: [
                "result": [
                    "rateLimits": [
                        "limitId": "codex",
                        "primary": ["usedPercent": 12, "windowDurationMins": 10_080, "resetsAt": 1_800_000_000],
                        "planType": "pro"
                    ],
                    "rateLimitsByLimitId": [
                        "spark": [
                            "limitId": "spark",
                            "limitName": "Spark",
                            "primary": ["usedPercent": 4, "windowDurationMins": 10_080, "resetsAt": 1_800_000_100]
                        ],
                        "codex": [
                            "limitId": "codex",
                            "primary": ["usedPercent": 12, "windowDurationMins": 10_080, "resetsAt": 1_800_000_000]
                        ]
                    ],
                    "rateLimitResetCredits": ["availableCount": 1]
                ]
            ],
            4: [
                "result": [
                    "summary": ["lifetimeTokens": 123_456, "peakDailyTokens": 45_678],
                    "dailyUsageBuckets": [["startDate": "2026-07-13", "tokens": 321]]
                ]
            ]
        ]

        do {
            let snapshot = try UsageResponseParser.parse(responses: responses)
            let checks: [(String, Bool)] = [
                ("usage parser", snapshot.planType == "pro"
                    && snapshot.buckets.map(\.id) == ["codex", "spark"]
                    && snapshot.primaryBucket?.remainingPercent == 88
                    && snapshot.lifetimeTokens == 123_456
                    && snapshot.dailyUsage.first?.tokens == 321
                    && snapshot.resetCredits == 1),
                ("security helpers", securityHelpersPass()),
                ("single-instance lock", applicationInstanceLockPass()),
                ("Codex process lifecycle", codexProcessLifecyclePass()),
                ("Claude helpers", claudeHelpersPass())
            ]
            let failures = checks.filter { !$0.1 }.map(\.0)
            let passed = failures.isEmpty

            print(passed ? "Self-test passed" : "Self-test failed: \(failures.joined(separator: ", "))")
            return passed
        } catch {
            print("Self-test failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func securityHelpersPass() -> Bool {
        var lines = BoundedJSONLineBuffer(maximumTotalBytes: 32, maximumLineBytes: 16)
        guard case .lines(let firstLines) = lines.append(Data("{\"id\":".utf8)),
              firstLines.isEmpty,
              case .lines(let completedLines) = lines.append(Data("3}\n".utf8)),
              completedLines == [Data("{\"id\":3}".utf8)] else {
            return false
        }

        var oversizedLine = BoundedJSONLineBuffer(maximumTotalBytes: 32, maximumLineBytes: 4)
        guard case .limitExceeded = oversizedLine.append(Data("12345".utf8)) else {
            return false
        }

        var totalLimit = BoundedJSONLineBuffer(maximumTotalBytes: 4, maximumLineBytes: 4)
        guard case .lines = totalLimit.append(Data("12".utf8)),
              case .limitExceeded = totalLimit.append(Data("345".utf8)) else {
            return false
        }

        var tail = BoundedDataTail(maximumBytes: 4)
        tail.append(Data("abcdef".utf8))
        tail.append(Data("gh".utf8))

        let safeMode = mode_t(S_IFREG | 0o755)
        return tail.data == Data("efgh".utf8)
            && CodexUsageFetcher.expectedResponseID(from: NSNumber(value: 3)) == 3
            && CodexUsageFetcher.expectedResponseID(from: NSNumber(value: 4.0)) == 4
            && CodexUsageFetcher.expectedResponseID(from: NSNumber(value: 3.5)) == nil
            && CodexUsageFetcher.expectedResponseID(from: NSNumber(value: true)) == nil
            && CodexUsageFetcher.expectedResponseID(from: NSNumber(value: 5)) == nil
            && CodexUsageFetcher.sanitizedServerError(from: "Unauthorized") == .signInRequired
            && CodexUsageFetcher.sanitizedServerError(from: "token=private-value") == .serverError
            && CodexUsageFetcher.isSafeExecutableMode(safeMode)
            && !CodexUsageFetcher.isSafeExecutableMode(safeMode | mode_t(S_IWOTH))
            && !CodexUsageFetcher.isSafeExecutableMode(safeMode | mode_t(S_ISUID))
            && !CodexUsageFetcher.isSafeExecutableMode(mode_t(S_IFDIR | 0o755))
    }

    private static func applicationInstanceLockPass() -> Bool {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-pulse-lock-test-\(UUID().uuidString)", isDirectory: true)
        let lockURL = root
            .appendingPathComponent("Library/Application Support/Codex Pulse", isDirectory: true)
            .appendingPathComponent("app-instance.lock", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }

        do {
            var firstLock: ApplicationInstanceLock? = try ApplicationInstanceLock(lockURL: lockURL)
            guard firstLock != nil else { return false }
            do {
                _ = try ApplicationInstanceLock(lockURL: lockURL)
                return false
            } catch ApplicationInstanceLockError.alreadyRunning {
                guard fileMode(lockURL) == 0o600 else { return false }
            }

            firstLock = nil
            let replacementLock = try ApplicationInstanceLock(lockURL: lockURL)
            withExtendedLifetime(replacementLock) {}
            return true
        } catch {
            return false
        }
    }

    private static func codexProcessLifecyclePass() -> Bool {
        func fail(_ detail: String) -> Bool {
            print("Codex process lifecycle self-test detail: \(detail)")
            return false
        }

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-pulse-process-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let successScript = root.appendingPathComponent("success.sh")
            let hangingScript = root.appendingPathComponent("hanging.sh")
            let rateResponse = """
            {"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1800000000},"planType":"pro"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1800000000}}},"rateLimitResetCredits":{"availableCount":1}}}
            """
            let usageResponse = """
            {"id":4,"result":{"summary":{"lifetimeTokens":123456,"peakDailyTokens":45678},"dailyUsageBuckets":[]}}
            """
            let successContents = """
            #!/bin/sh
            IFS= read -r _
            /usr/bin/printf '%s\\n' '{"id":1,"result":{"userAgent":"self-test"}}'
            IFS= read -r _
            IFS= read -r _
            IFS= read -r _
            /usr/bin/printf '%s\\n' '\(rateResponse)' '\(usageResponse)'
            exec /usr/bin/tail -f /dev/null
            """
            let hangingContents = """
            #!/bin/sh
            trap '' TERM
            exec /usr/bin/tail -f /dev/null
            """

            try Data(successContents.utf8).write(to: successScript)
            try Data(hangingContents.utf8).write(to: hangingScript)
            guard chmod(successScript.path, 0o700) == 0,
                  chmod(hangingScript.path, 0o700) == 0 else {
                return fail("could not make fixtures executable")
            }

            let environment = [
                "HOME": root.path,
                "TMPDIR": root.path,
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8"
            ]

            var successPID: pid_t = 0
            let successSnapshot = try CodexUsageFetcher.runExchange(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [successScript.path],
                environment: environment,
                startupDelay: 0,
                responseTimeout: 1,
                gracefulExitTimeout: 0.02,
                terminationTimeout: 0.05,
                processDidLaunch: { successPID = $0 }
            )
            guard successSnapshot.primaryBucket?.usedPercent == 12,
                  successPID > 0,
                  processIsGone(successPID) else {
                return fail("successful exchange did not parse or reap")
            }

            var timeoutPID: pid_t = 0
            do {
                _ = try CodexUsageFetcher.runExchange(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [hangingScript.path],
                    environment: environment,
                    startupDelay: 0,
                    responseTimeout: 0.05,
                    gracefulExitTimeout: 0.02,
                    terminationTimeout: 0.05,
                    processDidLaunch: { timeoutPID = $0 }
                )
                return fail("hanging exchange did not time out")
            } catch CodexUsageFetcherError.timedOut {
                guard timeoutPID > 0, processIsGone(timeoutPID) else {
                    return fail("timed-out exchange was not reaped")
                }
            } catch {
                return fail("hanging exchange returned \(error)")
            }

            let control = CodexFetchControl()
            let launched = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let resultBox = SelfTestBox<Result<UsageSnapshot, Error>>()
            let pidBox = SelfTestBox<pid_t>()

            DispatchQueue.global(qos: .utility).async {
                let result = Result {
                    try CodexUsageFetcher.runExchange(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: [hangingScript.path],
                        environment: environment,
                        control: control,
                        startupDelay: 0,
                        responseTimeout: 5,
                        gracefulExitTimeout: 0.02,
                        terminationTimeout: 0.05,
                        processDidLaunch: {
                            pidBox.set($0)
                            launched.signal()
                        }
                    )
                }
                resultBox.set(result)
                finished.signal()
            }

            guard launched.wait(timeout: .now() + 1) == .success else {
                return fail("cancellation fixture did not launch")
            }
            control.cancel()
            guard finished.wait(timeout: .now() + 1) == .success,
                  let cancelledResult = resultBox.get(),
                  let cancelledPID = pidBox.get(),
                  processIsGone(cancelledPID) else {
                return fail("cancelled exchange did not finish and reap")
            }

            switch cancelledResult {
            case .failure(let error as CodexUsageFetcherError):
                return error == .cancelled
                    ? true
                    : fail("cancelled exchange returned \(error)")
            default:
                return fail("cancelled exchange returned an unexpected result")
            }
        } catch {
            return fail("fixture setup or successful exchange returned \(error)")
        }
    }

    private static func processIsGone(_ processIdentifier: pid_t) -> Bool {
        errno = 0
        return kill(processIdentifier, 0) == -1 && errno == ESRCH
    }

    private static func claudeHelpersPass() -> Bool {
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let statusLineFixture: [String: Any] = [
            "cwd": "/private/project",
            "session_id": "private-session",
            "transcript_path": "/private/transcript.jsonl",
            "model": ["display_name": "Fable"],
            "cost": ["total_cost_usd": 12.34],
            "unrelated_private_field": "private-value",
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 60.0,
                    "resets_at": capturedAt.timeIntervalSince1970 + 3_600
                ],
                "seven_day": [
                    "used_percentage": 19.0,
                    "resets_at": capturedAt.timeIntervalSince1970 + 86_400
                ]
            ]
        ]
        guard let input = try? JSONSerialization.data(withJSONObject: statusLineFixture),
              let cache = try? ClaudeStatusLineCacheParser.filteredCache(
                from: input,
                previousCache: nil,
                capturedAt: capturedAt
              ),
              let cacheText = String(data: cache, encoding: .utf8),
              !cacheText.contains("private"),
              !cacheText.contains("session_id"),
              !cacheText.contains("transcript"),
              !cacheText.contains("Fable"),
              let snapshot = try? ClaudeStatusLineCacheParser.parse(
                data: cache,
                now: capturedAt.addingTimeInterval(120)
              ),
              snapshot.limits.map(\.usedPercent) == [60, 19],
              snapshot.limits.map(\.name) == [
                "Current session",
                "Current week (all models)"
              ],
              !snapshot.isStale else {
            return false
        }

        let singleWindowFixture: [String: Any] = [
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 0.0,
                    "resets_at": capturedAt.timeIntervalSince1970 + 3_600
                ]
            ]
        ]
        let boundaryFixture: [String: Any] = [
            "rate_limits": [
                "seven_day": [
                    "used_percentage": 100.0,
                    "resets_at": capturedAt.timeIntervalSince1970 + 86_400
                ]
            ]
        ]
        let booleanFixture: [String: Any] = [
            "rate_limits": [
                "five_hour": [
                    "used_percentage": true,
                    "resets_at": capturedAt.timeIntervalSince1970 + 3_600
                ]
            ]
        ]
        guard let singleInput = try? JSONSerialization.data(withJSONObject: singleWindowFixture),
              let singleCache = try? ClaudeStatusLineCacheParser.filteredCache(
                from: singleInput,
                previousCache: nil,
                capturedAt: capturedAt
              ),
              let singleSnapshot = try? ClaudeStatusLineCacheParser.parse(
                data: singleCache,
                now: capturedAt.addingTimeInterval(601)
              ),
              singleSnapshot.limits.map(\.usedPercent) == [0],
              singleSnapshot.isStale,
              let boundaryInput = try? JSONSerialization.data(withJSONObject: boundaryFixture),
              let boundaryCache = try? ClaudeStatusLineCacheParser.filteredCache(
                from: boundaryInput,
                previousCache: nil,
                capturedAt: capturedAt
              ),
              let boundarySnapshot = try? ClaudeStatusLineCacheParser.parse(
                data: boundaryCache,
                now: capturedAt.addingTimeInterval(120)
              ),
              boundarySnapshot.limits.map(\.usedPercent) == [100],
              let booleanInput = try? JSONSerialization.data(withJSONObject: booleanFixture),
              (try? ClaudeStatusLineCacheParser.filteredCache(
                from: booleanInput,
                previousCache: nil,
                capturedAt: capturedAt
              )) == nil else {
            return false
        }

        let expiredIsRejected = (try? ClaudeStatusLineCacheParser.parse(
            data: singleCache,
            now: capturedAt.addingTimeInterval(3_601)
        )) == nil

        return expiredIsRejected
            && ClaudeStatusLineBridge.shellQuoted("a'b") == "'a'\"'\"'b'"
            && bridgeRoundTripPass()
            && oversizedManifestFailsCleanly()
    }

    private static func bridgeRoundTripPass() -> Bool {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-pulse-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        let applicationSupport = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let executable = root
            .appendingPathComponent("Test.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("CodexUsageFloat", isDirectory: false)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let bridgeDirectory = applicationSupport.appendingPathComponent("Codex Pulse", isDirectory: true)
        let helperURL = bridgeDirectory.appendingPathComponent("ClaudeStatusLineBridge")
        let manifestURL = bridgeDirectory.appendingPathComponent("bridge-manifest.json")
        let markerURL = root.appendingPathComponent("original-command-ran")
        let forwardedURL = root.appendingPathComponent("forwarded-input")
        let originalCommand = "/bin/cat > \(ClaudeStatusLineBridge.shellQuoted(forwardedURL.path)); /usr/bin/touch \(ClaudeStatusLineBridge.shellQuoted(markerURL.path)); exit 7"
        let originalStatusLine: [String: Any] = [
            "type": "command",
            "command": originalCommand,
            "padding": 2,
            "refreshInterval": 11,
            "hideVimModeIndicator": true
        ]
        let originalSettings: [String: Any] = [
            "theme": "light",
            "statusLine": originalStatusLine
        ]

        do {
            try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            guard chmod(executable.path, 0o700) == 0 else { return false }
            let settingsData = try JSONSerialization.data(
                withJSONObject: originalSettings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try settingsData.write(to: settingsURL)
            guard chmod(settingsURL.path, 0o600) == 0 else { return false }

            let bridge = ClaudeStatusLineBridge(homeDirectory: root, executableURL: executable)
            try bridge.install()
            try bridge.install()

            let installedData = try Data(contentsOf: settingsURL)
            guard let installed = try JSONSerialization.jsonObject(with: installedData) as? [String: Any],
                  let installedStatusLine = installed["statusLine"] as? [String: Any],
                  installedStatusLine["command"] as? String != originalCommand,
                  installedStatusLine["padding"] as? Int == 2,
                  installedStatusLine["refreshInterval"] as? Int == 11,
                  installedStatusLine["hideVimModeIndicator"] as? Bool == true,
                  !fileManager.fileExists(atPath: markerURL.path),
                  fileMode(helperURL) == 0o700,
                  fileMode(manifestURL) == 0o600 else {
                return false
            }

            let manifestBackup = try Data(contentsOf: manifestURL)
            try fileManager.removeItem(at: manifestURL)
            let forwardedInput = Data("exact status-line input\nwith a second line\n".utf8)
            guard runHelper(helperURL, input: forwardedInput) == 7,
                  try Data(contentsOf: forwardedURL) == forwardedInput,
                  fileManager.fileExists(atPath: markerURL.path) else {
                return false
            }
            try manifestBackup.write(to: manifestURL)
            guard chmod(manifestURL.path, 0o600) == 0 else { return false }
            try fileManager.removeItem(at: markerURL)
            try fileManager.removeItem(at: forwardedURL)

            var adjustedSettings = installed
            var adjustedStatusLine = installedStatusLine
            adjustedStatusLine["padding"] = 3
            adjustedSettings["statusLine"] = adjustedStatusLine
            let adjustedData = try JSONSerialization.data(
                withJSONObject: adjustedSettings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try adjustedData.write(to: settingsURL, options: .atomic)
            guard chmod(settingsURL.path, 0o600) == 0 else { return false }

            try bridge.uninstall()
            let restoredData = try Data(contentsOf: settingsURL)
            guard let restored = try JSONSerialization.jsonObject(with: restoredData) as? [String: Any],
                  let restoredStatusLine = restored["statusLine"] as? [String: Any],
                  restoredStatusLine["command"] as? String == originalCommand,
                  restoredStatusLine["padding"] as? Int == 3,
                  restoredStatusLine["refreshInterval"] as? Int == 11,
                  restored["theme"] as? String == "light",
                  !fileManager.fileExists(atPath: helperURL.path),
                  !fileManager.fileExists(atPath: manifestURL.path),
                  !fileManager.fileExists(atPath: markerURL.path) else {
                return false
            }

            try bridge.install()
            var conflictingSettings = try JSONSerialization.jsonObject(
                with: Data(contentsOf: settingsURL)
            ) as? [String: Any] ?? [:]
            var conflictingStatusLine = conflictingSettings["statusLine"] as? [String: Any] ?? [:]
            conflictingStatusLine["padding"] = 9
            conflictingStatusLine["command"] = "printf '%s' 'new user command'"
            conflictingSettings["statusLine"] = conflictingStatusLine
            let conflictingData = try JSONSerialization.data(
                withJSONObject: conflictingSettings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try conflictingData.write(to: settingsURL, options: .atomic)
            guard chmod(settingsURL.path, 0o600) == 0 else { return false }

            do {
                try bridge.uninstall()
                return false
            } catch ClaudeUsageFetcherError.cleanupConflict {
                let currentData = try Data(contentsOf: settingsURL)
                let current = try JSONSerialization.jsonObject(with: currentData) as? [String: Any]
                let currentStatusLine = current?["statusLine"] as? [String: Any]
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
                return currentStatusLine?["padding"] as? Int == 9
                    && currentStatusLine?["command"] as? String == "printf '%s' 'new user command'"
                    && manifest?["capture_enabled"] as? Bool == false
                    && fileMode(manifestURL) == 0o600
            }
        } catch {
            return false
        }
    }

    private static func fileMode(_ url: URL) -> mode_t? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else { return nil }
        return status.st_mode & 0o777
    }

    private static func oversizedManifestFailsCleanly() -> Bool {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-pulse-size-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let claudeDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        let applicationSupport = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let executable = root
            .appendingPathComponent("Test.app/Contents/MacOS/CodexUsageFloat")
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let bridgeDirectory = applicationSupport.appendingPathComponent("Codex Pulse", isDirectory: true)
        let helperURL = bridgeDirectory.appendingPathComponent("ClaudeStatusLineBridge")
        let manifestURL = bridgeDirectory.appendingPathComponent("bridge-manifest.json")
        let longCommand = String(repeating: "\u{0001}", count: 65_536)
        let settings: [String: Any] = [
            "statusLine": ["type": "command", "command": longCommand]
        ]

        do {
            try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            guard chmod(executable.path, 0o700) == 0 else { return false }
            let settingsData = try JSONSerialization.data(withJSONObject: settings)
            try settingsData.write(to: settingsURL)
            guard chmod(settingsURL.path, 0o600) == 0 else { return false }

            let bridge = ClaudeStatusLineBridge(homeDirectory: root, executableURL: executable)
            do {
                try bridge.install()
                return false
            } catch ClaudeUsageFetcherError.unsupportedStatusLine {
                let currentData = try Data(contentsOf: settingsURL)
                let current = try JSONSerialization.jsonObject(with: currentData) as? [String: Any]
                let currentStatusLine = current?["statusLine"] as? [String: Any]
                return currentStatusLine?["command"] as? String == longCommand
                    && !fileManager.fileExists(atPath: helperURL.path)
                    && !fileManager.fileExists(atPath: manifestURL.path)
            }
        } catch {
            return false
        }
    }

    private static func runHelper(_ url: URL, input: Data) -> Int32? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = url
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try pipe.fileHandleForWriting.write(contentsOf: input)
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            try? pipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            return nil
        }
    }
}
