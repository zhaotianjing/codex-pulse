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

protocol CodexUsageFetching: AnyObject {
    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void)
    func cancelAndWait()
}

final class CodexFetchControl {
    private let lock = NSLock()
    private var process: Process?
    private var completionSignal: DispatchSemaphore?
    private var cancelled = false
    private var cancellationSignalSent = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(process: Process, completionSignal: DispatchSemaphore) {
        lock.lock()
        self.process = process
        self.completionSignal = completionSignal
        let shouldCancel = cancelled
        let shouldSignal = shouldCancel && !cancellationSignalSent
        if shouldSignal {
            cancellationSignalSent = true
        }
        lock.unlock()

        if shouldSignal {
            completionSignal.signal()
        }
        if shouldCancel, process.isRunning {
            kill(process.processIdentifier, SIGTERM)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let attachedProcess = process
        let signal = completionSignal
        let shouldSignal = signal != nil && !cancellationSignalSent
        if shouldSignal {
            cancellationSignalSent = true
        }
        lock.unlock()

        if shouldSignal {
            signal?.signal()
        }
        if let attachedProcess, attachedProcess.isRunning {
            kill(attachedProcess.processIdentifier, SIGTERM)
        }
    }

    func detach(process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
            completionSignal = nil
        }
        lock.unlock()
    }
}

enum CodexUsageFetcherError: LocalizedError, Equatable {
    case codexNotFound
    case codexNotTrusted
    case launchFailed
    case timedOut
    case cancelled
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
        case .cancelled:
            return "The Codex refresh was cancelled."
        case .signInRequired:
            return "Codex is not signed in. Open ChatGPT or Codex, sign in, and try again."
        case .invalidResponse:
            return "Codex returned an unexpected response. Update ChatGPT or Codex and try again."
        case .serverError:
            return "Codex could not provide usage data. Open ChatGPT or Codex and try again."
        }
    }
}

final class CodexUsageFetcher: CodexUsageFetching {
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

    private struct CandidateFingerprint: Equatable {
        let bundlePath: String?
        let bundleIdentity: ExecutableIdentity?
        let codeResourcesIdentity: ExecutableIdentity?
        let executablePath: String
        let executableIdentity: ExecutableIdentity?
    }

    private enum DiscoveryOutcome {
        case success(TrustedExecutable)
        case failure(CodexUsageFetcherError)
    }

    private struct DiscoveryCache {
        let fingerprint: [CandidateFingerprint]
        let outcome: DiscoveryOutcome
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
    private let activeControlsLock = NSLock()
    private var activeControls: [CodexFetchControl] = []
    private let discoveryCacheLock = NSLock()
    private var discoveryCache: DiscoveryCache?

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        let control = CodexFetchControl()
        activeControlsLock.lock()
        activeControls.append(control)
        activeControlsLock.unlock()

        worker.async {
            let result = Result { try self.fetchSynchronously(control: control) }
            self.activeControlsLock.lock()
            self.activeControls.removeAll { $0 === control }
            self.activeControlsLock.unlock()

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func cancelAndWait() {
        activeControlsLock.lock()
        let controls = activeControls
        activeControlsLock.unlock()

        controls.forEach { $0.cancel() }
        worker.sync {}
    }

    func fetchSynchronously() throws -> UsageSnapshot {
        try fetchSynchronously(control: nil)
    }

    private func fetchSynchronously(control: CodexFetchControl?) throws -> UsageSnapshot {
        if control?.isCancelled == true {
            throw CodexUsageFetcherError.cancelled
        }
        let trustedExecutable = try locateTrustedCodex()
        if control?.isCancelled == true {
            throw CodexUsageFetcherError.cancelled
        }
        guard trustedExecutable.isUnchanged else {
            throw CodexUsageFetcherError.codexNotTrusted
        }

        return try Self.runExchange(
            executableURL: trustedExecutable.url,
            arguments: ["app-server", "--stdio"],
            environment: safeChildEnvironment(),
            control: control
        )
    }

    static func runExchange(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        control: CodexFetchControl? = nil,
        startupDelay: TimeInterval = 1,
        responseTimeout: TimeInterval = 18,
        gracefulExitTimeout: TimeInterval = 0.25,
        terminationTimeout: TimeInterval = 0.5,
        processDidLaunch: ((pid_t) -> Void)? = nil
    ) throws -> UsageSnapshot {
        if control?.isCancelled == true {
            throw CodexUsageFetcherError.cancelled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let lock = NSLock()
        let completed = DispatchSemaphore(value: 0)
        var outputBuffer = BoundedJSONLineBuffer(
            maximumTotalBytes: Self.maximumOutputBytes,
            maximumLineBytes: Self.maximumLineBytes
        )
        var errorBuffer = BoundedDataTail(maximumBytes: Self.maximumErrorBytes)
        var responses: [Int: [String: Any]] = [:]
        var initializeResponse: [String: Any]?
        var streamFailure: CodexUsageFetcherError?
        var awaitingInitialization = true
        var phaseSignalSent = false

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

            if streamFailure != nil, !phaseSignalSent {
                phaseSignalSent = true
                completed.signal()
            }
            lock.unlock()

            guard case .lines(let lines) = appendResult else { return }

            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = Self.responseID(from: object["id"]) else { continue }

                lock.lock()
                if streamFailure == nil {
                    if responseID == 1 {
                        initializeResponse = object
                    } else if !awaitingInitialization,
                              Self.expectedResponseIDs.contains(responseID) {
                        responses[responseID] = object
                    }

                    let phaseComplete = awaitingInitialization
                        ? initializeResponse != nil
                        : Self.expectedResponseIDs.allSatisfy { responses[$0] != nil }
                    if phaseComplete, !phaseSignalSent {
                        phaseSignalSent = true
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
            if !phaseSignalSent {
                streamFailure = .serverError
                phaseSignalSent = true
                completed.signal()
            }
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw CodexUsageFetcherError.launchFailed
        }

        control?.attach(process: process, completionSignal: completed)
        processDidLaunch?(process.processIdentifier)

        defer {
            try? inputPipe.fileHandleForWriting.close()
            terminateAndReap(
                process,
                gracefulExitTimeout: gracefulExitTimeout,
                terminationTimeout: terminationTimeout
            )
            control?.detach(process: process)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }

        let startupDeadline = Date().addingTimeInterval(startupDelay)
        while Date() < startupDeadline {
            if control?.isCancelled == true {
                throw CodexUsageFetcherError.cancelled
            }
            usleep(10_000)
        }

        let initializeMessage: [String: Any] = [
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "codex-usage-float",
                    "title": "Codex Pulse",
                    "version": "1.2.1"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false
                ]
            ]
        ]
        let requestMessages: [[String: Any]] = [
            ["method": "initialized"],
            ["method": "account/rateLimits/read", "id": 3],
            ["method": "account/usage/read", "id": 4]
        ]

        do {
            for message in [initializeMessage] {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0x0A)
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
        } catch {
            if control?.isCancelled == true {
                throw CodexUsageFetcherError.cancelled
            }
            throw CodexUsageFetcherError.serverError
        }

        let initializeWaitResult = completed.wait(timeout: .now() + responseTimeout)

        lock.lock()
        let capturedInitializeResponse = initializeResponse
        let capturedInitializeFailure = streamFailure
        let capturedInitializeError = errorBuffer.data
        lock.unlock()

        if control?.isCancelled == true {
            throw CodexUsageFetcherError.cancelled
        }
        if let capturedInitializeFailure {
            throw capturedInitializeFailure
        }
        guard initializeWaitResult == .success, let capturedInitializeResponse else {
            let detail = String(data: capturedInitializeError, encoding: .utf8)
            if detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw Self.sanitizedServerError(from: detail)
            }
            throw CodexUsageFetcherError.timedOut
        }
        if let error = capturedInitializeResponse["error"] as? [String: Any] {
            throw Self.sanitizedServerError(from: error["message"] as? String)
        }

        lock.lock()
        awaitingInitialization = false
        phaseSignalSent = false
        lock.unlock()

        do {
            for message in requestMessages {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0x0A)
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
        } catch {
            if control?.isCancelled == true {
                throw CodexUsageFetcherError.cancelled
            }
            throw CodexUsageFetcherError.serverError
        }

        let waitResult = completed.wait(timeout: .now() + responseTimeout)

        lock.lock()
        let capturedResponses = responses
        let capturedFailure = streamFailure
        let capturedError = errorBuffer.data
        lock.unlock()

        if control?.isCancelled == true {
            throw CodexUsageFetcherError.cancelled
        }

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
        let candidates: [CodexCandidate]

        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_CODEX_BIN"],
           !override.isEmpty {
            guard NSString(string: override).isAbsolutePath else {
                throw CodexUsageFetcherError.codexNotTrusted
            }
            candidates = [
                CodexCandidate(
                    bundleURL: nil,
                    executableURL: URL(fileURLWithPath: override)
                )
            ]
        } else {
            let userApplications = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            let applicationRoots = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplications
            ]
            let appNames = ["ChatGPT.app", "Codex.app"]
            var discoveredCandidates: [CodexCandidate] = []

            for root in applicationRoots {
                for appName in appNames {
                    let bundleURL = root.appendingPathComponent(appName, isDirectory: true)
                    let executableURL = bundleURL
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent("codex", isDirectory: false)
                    discoveredCandidates.append(
                        CodexCandidate(bundleURL: bundleURL, executableURL: executableURL)
                    )
                }
            }

            discoveredCandidates.append(contentsOf: [
                CodexCandidate(
                    bundleURL: nil,
                    executableURL: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".local/bin/codex")
                ),
                CodexCandidate(
                    bundleURL: nil,
                    executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex")
                ),
                CodexCandidate(
                    bundleURL: nil,
                    executableURL: URL(fileURLWithPath: "/usr/local/bin/codex")
                )
            ])
            candidates = discoveredCandidates
        }

        let fingerprint = candidates.map(Self.fingerprint)
        discoveryCacheLock.lock()
        let cachedDiscovery = discoveryCache
        discoveryCacheLock.unlock()

        if let cachedDiscovery, cachedDiscovery.fingerprint == fingerprint {
            switch cachedDiscovery.outcome {
            case .success(let trustedExecutable) where trustedExecutable.isUnchanged:
                return trustedExecutable
            case .success:
                break
            case .failure(let error):
                throw error
            }
        }

        var foundUntrustedCandidate = false

        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.executableURL.path) else {
                continue
            }
            foundUntrustedCandidate = true

            if let trustedExecutable = validateOpenAICandidate(candidate) {
                cacheDiscovery(
                    DiscoveryCache(
                        fingerprint: fingerprint,
                        outcome: .success(trustedExecutable)
                    )
                )
                return trustedExecutable
            }
        }

        if foundUntrustedCandidate {
            let error = CodexUsageFetcherError.codexNotTrusted
            cacheDiscovery(DiscoveryCache(fingerprint: fingerprint, outcome: .failure(error)))
            throw error
        }
        let error = CodexUsageFetcherError.codexNotFound
        cacheDiscovery(DiscoveryCache(fingerprint: fingerprint, outcome: .failure(error)))
        throw error
    }

    private func cacheDiscovery(_ cache: DiscoveryCache) {
        discoveryCacheLock.lock()
        discoveryCache = cache
        discoveryCacheLock.unlock()
    }

    private static func fingerprint(_ candidate: CodexCandidate) -> CandidateFingerprint {
        let executableURL = candidate.executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let bundleURL = candidate.bundleURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let codeResourcesURL = bundleURL?
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_CodeSignature", isDirectory: true)
            .appendingPathComponent("CodeResources", isDirectory: false)

        return CandidateFingerprint(
            bundlePath: bundleURL?.path,
            bundleIdentity: bundleURL.flatMap(ExecutableIdentity.init(url:)),
            codeResourcesIdentity: codeResourcesURL.flatMap(ExecutableIdentity.init(url:)),
            executablePath: executableURL.path,
            executableIdentity: ExecutableIdentity(url: executableURL)
        )
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
                      flags: SecCSFlags(rawValue: commonFlags)
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
        guard let responseID = responseID(from: value),
              expectedResponseIDs.contains(responseID) else {
            return nil
        }
        return responseID
    }

    private static func responseID(from value: Any?) -> Int? {
        guard let idNumber = value as? NSNumber,
              CFGetTypeID(idNumber) != CFBooleanGetTypeID() else {
            return nil
        }

        let responseID = idNumber.intValue
        guard idNumber.compare(NSNumber(value: responseID)) == .orderedSame else {
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

    static func terminateAndReap(
        _ process: Process,
        gracefulExitTimeout: TimeInterval,
        terminationTimeout: TimeInterval
    ) {
        if process.isRunning {
            let gracefulDeadline = Date().addingTimeInterval(gracefulExitTimeout)
            while process.isRunning, Date() < gracefulDeadline {
                usleep(10_000)
            }
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGTERM)
            let terminationDeadline = Date().addingTimeInterval(terminationTimeout)
            while process.isRunning, Date() < terminationDeadline {
                usleep(10_000)
            }
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        process.waitUntilExit()
    }
}
