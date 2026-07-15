import Darwin
import Foundation
import Security

enum BoundedJSONLineBufferAppendResult {
    case lines([Data])
    case limitExceeded
}

struct BoundedJSONLineBuffer {
    private let maximumTotalBytes: Int
    private let maximumLineBytes: Int
    private var totalBytes = 0
    private var buffer = Data()
    private var didExceedLimit = false

    init(maximumTotalBytes: Int, maximumLineBytes: Int) {
        precondition(maximumTotalBytes > 0 && maximumLineBytes > 0)
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) -> BoundedJSONLineBufferAppendResult {
        guard !didExceedLimit,
              data.count <= maximumTotalBytes - totalBytes else {
            didExceedLimit = true
            buffer.removeAll(keepingCapacity: false)
            return .limitExceeded
        }

        totalBytes += data.count
        buffer.append(data)
        var lines: [Data] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)

            guard line.count <= maximumLineBytes else {
                didExceedLimit = true
                buffer.removeAll(keepingCapacity: false)
                return .limitExceeded
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }

        guard buffer.count <= maximumLineBytes else {
            didExceedLimit = true
            buffer.removeAll(keepingCapacity: false)
            return .limitExceeded
        }

        return .lines(lines)
    }
}

struct BoundedDataTail {
    private let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ newData: Data) {
        if newData.count >= maximumBytes {
            data = Data(newData.suffix(maximumBytes))
            return
        }

        let overflow = data.count + newData.count - maximumBytes
        if overflow > 0 {
            data.removeFirst(overflow)
        }
        data.append(newData)
    }
}

enum CodexUsageFetcherError: LocalizedError, Equatable {
    case codexNotFound
    case codexNotTrusted
    case launchFailed
    case timedOut
    case signInRequired
    case invalidResponse
    case serverError

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex was not found. Install ChatGPT or Codex from OpenAI and sign in first."
        case .codexNotTrusted:
            return "The Codex installation could not be verified. Update or reinstall ChatGPT or Codex from OpenAI, then try again."
        case .launchFailed:
            return "Could not start Codex. Open ChatGPT or Codex and try again."
        case .timedOut:
            return "The Codex connection timed out. Try again later."
        case .signInRequired:
            return "Codex is not signed in. Open ChatGPT or Codex, sign in, and try again."
        case .invalidResponse:
            return "Codex returned an unexpected response. Update ChatGPT or Codex and try again."
        case .serverError:
            return "Codex could not provide usage data. Open ChatGPT or Codex and try again."
        }
    }
}

final class CodexUsageFetcher {
    private struct CodexCandidate {
        let bundleURL: URL?
        let executableURL: URL
    }

    private struct ExecutableIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modificationSeconds: time_t
        let modificationNanoseconds: Int64
        let statusChangeSeconds: time_t
        let statusChangeNanoseconds: Int64

        init?(url: URL) {
            var fileStatus = stat()
            guard url.path.withCString({ lstat($0, &fileStatus) }) == 0 else {
                return nil
            }

            device = fileStatus.st_dev
            inode = fileStatus.st_ino
            size = fileStatus.st_size
            mode = fileStatus.st_mode
            modificationSeconds = fileStatus.st_mtimespec.tv_sec
            modificationNanoseconds = Int64(fileStatus.st_mtimespec.tv_nsec)
            statusChangeSeconds = fileStatus.st_ctimespec.tv_sec
            statusChangeNanoseconds = Int64(fileStatus.st_ctimespec.tv_nsec)
        }
    }

    private struct TrustedExecutable {
        let url: URL
        let identity: ExecutableIdentity

        var isUnchanged: Bool {
            ExecutableIdentity(url: url) == identity
        }
    }

    private static let maximumOutputBytes = 1_048_576
    private static let maximumLineBytes = 262_144
    private static let maximumErrorBytes = 65_536
    private static let expectedResponseIDs: Set<Int> = [3, 4]
    private static let openAITeamIdentifier = "2DC432GLL2"
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let codexExecutableIdentifier = "codex"
    private static let developerIDCertificateRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    // Security/CSCommon.h defines kSecCSNoNetworkAccess as bit 29, but Swift does not import it.
    private static let noNetworkValidationFlag: UInt32 = 1 << 29

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
        let trustedExecutable = try locateTrustedCodex()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = trustedExecutable.url
        process.arguments = ["app-server", "--stdio"]
        process.environment = safeChildEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lock = NSLock()
        let completed = DispatchSemaphore(value: 0)
        var outputBuffer = BoundedJSONLineBuffer(
            maximumTotalBytes: Self.maximumOutputBytes,
            maximumLineBytes: Self.maximumLineBytes
        )
        var errorBuffer = BoundedDataTail(maximumBytes: Self.maximumErrorBytes)
        var responses: [Int: [String: Any]] = [:]
        var streamFailure: CodexUsageFetcherError?
        var didSignal = false

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            lock.lock()
            if streamFailure != nil {
                lock.unlock()
                return
            }
            let appendResult = outputBuffer.append(data)
            if case .limitExceeded = appendResult {
                streamFailure = .invalidResponse
            }

            if streamFailure != nil, !didSignal {
                didSignal = true
                completed.signal()
            }
            lock.unlock()

            guard case .lines(let lines) = appendResult else { return }

            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = Self.expectedResponseID(from: object["id"]) else { continue }

                lock.lock()
                if streamFailure == nil {
                    responses[responseID] = object
                    if Self.expectedResponseIDs.allSatisfy({ responses[$0] != nil }), !didSignal {
                        didSignal = true
                        completed.signal()
                    }
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

        process.terminationHandler = { _ in
            lock.lock()
            if !didSignal {
                streamFailure = .serverError
                didSignal = true
                completed.signal()
            }
            lock.unlock()
        }

        guard trustedExecutable.isUnchanged else {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw CodexUsageFetcherError.codexNotTrusted
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw CodexUsageFetcherError.launchFailed
        }

        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            terminateAndReap(process)
            process.terminationHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "codex-usage-float",
                        "title": "Codex Pulse",
                        "version": "1.1.0"
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

        do {
            for message in messages {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0x0A)
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
        } catch {
            throw CodexUsageFetcherError.serverError
        }

        let waitResult = completed.wait(timeout: .now() + 18)

        lock.lock()
        let capturedResponses = responses
        let capturedFailure = streamFailure
        let capturedError = errorBuffer.data
        lock.unlock()

        if let capturedFailure {
            throw capturedFailure
        }

        guard waitResult == .success else {
            let detail = String(data: capturedError, encoding: .utf8)
            if detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw Self.sanitizedServerError(from: detail)
            }
            throw CodexUsageFetcherError.timedOut
        }

        for responseID in Self.expectedResponseIDs {
            if let error = capturedResponses[responseID]?["error"] as? [String: Any] {
                throw Self.sanitizedServerError(from: error["message"] as? String)
            }
        }

        return try UsageResponseParser.parse(responses: capturedResponses)
    }

    private func locateTrustedCodex() throws -> TrustedExecutable {
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let applicationRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            userApplications
        ]
        let appNames = ["ChatGPT.app", "Codex.app"]
        var candidates: [CodexCandidate] = []
        var foundUntrustedCandidate = false

        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_CODEX_BIN"],
           !override.isEmpty {
            guard NSString(string: override).isAbsolutePath else {
                throw CodexUsageFetcherError.codexNotTrusted
            }

            let overrideCandidate = CodexCandidate(
                bundleURL: nil,
                executableURL: URL(fileURLWithPath: override)
            )
            guard FileManager.default.isExecutableFile(atPath: overrideCandidate.executableURL.path) else {
                throw CodexUsageFetcherError.codexNotFound
            }
            guard let trustedOverride = validateOpenAICandidate(overrideCandidate) else {
                throw CodexUsageFetcherError.codexNotTrusted
            }
            return trustedOverride
        }

        for root in applicationRoots {
            for appName in appNames {
                let bundleURL = root.appendingPathComponent(appName, isDirectory: true)
                let executableURL = bundleURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
                candidates.append(CodexCandidate(bundleURL: bundleURL, executableURL: executableURL))
            }
        }

        candidates.append(contentsOf: [
            CodexCandidate(
                bundleURL: nil,
                executableURL: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/codex")
            ),
            CodexCandidate(bundleURL: nil, executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex")),
            CodexCandidate(bundleURL: nil, executableURL: URL(fileURLWithPath: "/usr/local/bin/codex"))
        ])

        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.executableURL.path) else {
                continue
            }
            foundUntrustedCandidate = true

            if let trustedExecutable = validateOpenAICandidate(candidate) {
                return trustedExecutable
            }
        }

        if foundUntrustedCandidate {
            throw CodexUsageFetcherError.codexNotTrusted
        }
        throw CodexUsageFetcherError.codexNotFound
    }

    private func validateOpenAICandidate(_ candidate: CodexCandidate) -> TrustedExecutable? {
        let executableURL = candidate.executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              let identityBeforeValidation = ExecutableIdentity(url: executableURL),
              Self.isSafeExecutableMode(identityBeforeValidation.mode) else {
            return nil
        }

        let commonFlags = kSecCSCheckAllArchitectures
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
            | kSecCSRestrictSidebandData
            | Self.noNetworkValidationFlag
        let executableRequirement = Self.codeRequirement(identifier: Self.codexExecutableIdentifier)

        if let originalBundleURL = candidate.bundleURL {
            let bundleURL = originalBundleURL.resolvingSymlinksInPath().standardizedFileURL
            let expectedExecutableURL = bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false)
                .resolvingSymlinksInPath()
                .standardizedFileURL

            guard executableURL == expectedExecutableURL,
                  validateCode(
                      at: bundleURL,
                      requirement: Self.codeRequirement(identifier: Self.codexBundleIdentifier),
                      flags: SecCSFlags(rawValue: commonFlags | kSecCSCheckNestedCode)
                  ) else {
                return nil
            }
        }

        guard validateCode(
            at: executableURL,
            requirement: executableRequirement,
            flags: SecCSFlags(rawValue: commonFlags)
        ),
        let identityAfterValidation = ExecutableIdentity(url: executableURL),
        identityAfterValidation == identityBeforeValidation else {
            return nil
        }

        return TrustedExecutable(url: executableURL, identity: identityAfterValidation)
    }

    private func validateCode(at url: URL, requirement: String, flags: SecCSFlags) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }

        var codeRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &codeRequirement) == errSecSuccess,
              let codeRequirement else {
            return false
        }

        var validationError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            flags,
            codeRequirement,
            &validationError
        )
        if let validationError {
            _ = validationError.takeRetainedValue()
        }
        return status == errSecSuccess
    }

    private static func codeRequirement(identifier: String) -> String {
        "identifier \"\(identifier)\" and \(developerIDCertificateRequirement) and certificate leaf[subject.OU] = \"\(openAITeamIdentifier)\""
    }

    static func expectedResponseID(from value: Any?) -> Int? {
        guard let idNumber = value as? NSNumber,
              CFGetTypeID(idNumber) != CFBooleanGetTypeID() else {
            return nil
        }

        let responseID = idNumber.intValue
        guard idNumber.compare(NSNumber(value: responseID)) == .orderedSame,
              expectedResponseIDs.contains(responseID) else {
            return nil
        }
        return responseID
    }

    static func isSafeExecutableMode(_ mode: mode_t) -> Bool {
        let prohibitedBits = mode_t(S_ISUID | S_ISGID | S_IWOTH)
        return mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && mode & prohibitedBits == 0
    }

    private func safeChildEnvironment() -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
    }

    static func sanitizedServerError(from detail: String?) -> CodexUsageFetcherError {
        let normalized = detail?.lowercased() ?? ""
        let authenticationIndicators = [
            "not logged in",
            "not signed in",
            "sign in",
            "signin",
            "unauthorized",
            "authentication required",
            "login required"
        ]

        if authenticationIndicators.contains(where: normalized.contains) {
            return .signInRequired
        }
        return .serverError
    }

    private func terminateAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()

            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < deadline {
                usleep(10_000)
            }

            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
    }
}
