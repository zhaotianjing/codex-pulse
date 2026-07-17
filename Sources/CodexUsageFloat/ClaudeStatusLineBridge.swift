import Darwin
import Foundation

final class ClaudeStatusLineBridge {
    static let maximumInputBytes = 1_048_576
    static let maximumCacheBytes = 65_536

    private static let maximumSettingsBytes = 1_048_576
    private static let maximumManifestBytes = 131_072
    private static let manifestSchemaVersion = 1

    private let homeDirectory: URL
    private let executableURL: URL?
    private let applicationSupportDirectory: URL
    private let helperURL: URL
    private let manifestURL: URL
    private let cacheURL: URL
    private let claudeDirectory: URL
    private let settingsURL: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL? = Bundle.main.executableURL
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.executableURL = executableURL?.standardizedFileURL
        applicationSupportDirectory = self.homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex Pulse", isDirectory: true)
        helperURL = applicationSupportDirectory
            .appendingPathComponent("ClaudeStatusLineBridge", isDirectory: false)
        manifestURL = applicationSupportDirectory
            .appendingPathComponent("bridge-manifest.json", isDirectory: false)
        cacheURL = applicationSupportDirectory
            .appendingPathComponent("claude-rate-limits.json", isDirectory: false)
        claudeDirectory = self.homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        settingsURL = claudeDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    func install() throws {
        guard let executableURL,
              executableURL.path.hasSuffix("/Contents/MacOS/CodexUsageFloat"),
              SecureBridgeFiles.isSafeExecutable(executableURL) else {
            throw ClaudeUsageFetcherError.settingsUnavailable
        }

        do {
            try SecureBridgeFiles.ensureOwnedDirectory(applicationSupportDirectory, mode: 0o700)
            try SecureBridgeFiles.ensureOwnedDirectory(claudeDirectory, mode: 0o700)

            try SecureBridgeFiles.withExclusiveDirectoryLock(applicationSupportDirectory) {
                let settingsFile = try readSettings()
                var settings = settingsFile.object
                let installedCommand = Self.shellQuoted(helperURL.path)
                let currentStatusLine = settings["statusLine"]
                let currentCommand = Self.command(from: currentStatusLine)

                let existingManifest = try? readManifest()
                let originalStatusLine: Any?
                if let existingManifest,
                   currentCommand == existingManifest.installedCommand {
                    originalStatusLine = existingManifest.originalStatusLine
                } else {
                    if currentCommand == installedCommand || currentCommand?.contains(helperURL.path) == true {
                        throw ClaudeUsageFetcherError.unsupportedStatusLine
                    }
                    try Self.validatePreservableStatusLine(currentStatusLine)
                    originalStatusLine = currentStatusLine
                }

                let originalCommand = Self.command(from: originalStatusLine)
                var installedStatusLine = (currentStatusLine as? [String: Any])
                    ?? (originalStatusLine as? [String: Any])
                    ?? [:]
                installedStatusLine["type"] = "command"
                installedStatusLine["command"] = installedCommand

                let manifest = BridgeManifest(
                    enabled: true,
                    installedCommand: installedCommand,
                    originalStatusLine: originalStatusLine,
                    installedStatusLine: installedStatusLine,
                    originalCommand: originalCommand
                )

                try writeManifest(manifest)
                try writeHelper(executableURL: executableURL, originalCommand: originalCommand)
                settings["statusLine"] = installedStatusLine
                try writeSettings(
                    settings,
                    mode: settingsFile.mode,
                    expectedIdentity: settingsFile.identity
                )
                try? SecureBridgeFiles.removeOwnedRegularFile(cacheURL)
            }
        } catch let error as ClaudeUsageFetcherError {
            throw error
        } catch {
            throw ClaudeUsageFetcherError.settingsUnavailable
        }
    }

    func uninstall() throws {
        do {
            try SecureBridgeFiles.ensureOwnedDirectory(applicationSupportDirectory, mode: 0o700)
            try SecureBridgeFiles.withExclusiveDirectoryLock(applicationSupportDirectory) {
              guard var manifest = try readManifestIfPresent() else {
                let settings = try readSettings().object
                let command = Self.command(from: settings["statusLine"])
                if command == Self.shellQuoted(helperURL.path)
                    || command?.contains(helperURL.path) == true {
                    throw ClaudeUsageFetcherError.cleanupConflict
                }
                try? SecureBridgeFiles.removeOwnedRegularFile(cacheURL)
                try? SecureBridgeFiles.removeOwnedRegularFile(helperURL)
                return
              }

            if manifest.enabled {
                manifest.enabled = false
                try writeManifest(manifest)
            }
            try? SecureBridgeFiles.removeOwnedRegularFile(cacheURL)

            let settingsFile = try readSettings()
            let currentStatusLine = settingsFile.object["statusLine"]
            guard Self.command(from: currentStatusLine) == manifest.installedCommand,
                  Self.type(from: currentStatusLine) == "command" else {
                throw ClaudeUsageFetcherError.cleanupConflict
            }

            var restoredSettings = settingsFile.object
            if let originalStatusLine = manifest.originalStatusLine {
                guard var currentObject = currentStatusLine as? [String: Any],
                      let originalObject = originalStatusLine as? [String: Any],
                      let originalCommand = Self.command(from: originalObject) else {
                    throw ClaudeUsageFetcherError.cleanupConflict
                }
                currentObject["type"] = originalObject["type"] ?? "command"
                currentObject["command"] = originalCommand
                restoredSettings["statusLine"] = currentObject
            } else {
                restoredSettings.removeValue(forKey: "statusLine")
            }
            try writeSettings(
                restoredSettings,
                mode: settingsFile.mode,
                expectedIdentity: settingsFile.identity
            )

            try SecureBridgeFiles.removeOwnedRegularFile(cacheURL)
            try SecureBridgeFiles.removeOwnedRegularFile(helperURL)
            try SecureBridgeFiles.removeOwnedRegularFile(manifestURL)
            }
        } catch let error as ClaudeUsageFetcherError {
            throw error
        } catch {
            throw ClaudeUsageFetcherError.settingsUnavailable
        }
    }

    func readSnapshot(now: Date = Date()) throws -> ClaudeUsageSnapshot {
        do {
            guard try SecureBridgeFiles.validateOwnedDirectoryIfPresent(applicationSupportDirectory) else {
                throw ClaudeUsageFetcherError.bridgeNotInstalled
            }
            return try SecureBridgeFiles.withExclusiveDirectoryLock(applicationSupportDirectory) {
                guard let manifest = try readManifestIfPresent(), manifest.enabled else {
                    throw ClaudeUsageFetcherError.bridgeNotInstalled
                }
                let settings = try readSettings().object
                guard Self.command(from: settings["statusLine"]) == manifest.installedCommand,
                      Self.type(from: settings["statusLine"]) == "command" else {
                    throw ClaudeUsageFetcherError.bridgeNotInstalled
                }
                guard let cache = try SecureBridgeFiles.readIfPresent(
                    cacheURL,
                    maximumBytes: Self.maximumCacheBytes,
                    privacy: .privateFile
                ) else {
                    throw ClaudeUsageFetcherError.awaitingClaudeResponse
                }
                return try ClaudeStatusLineCacheParser.parse(data: cache.data, now: now)
            }
        } catch let error as ClaudeUsageFetcherError {
            throw error
        } catch {
            throw ClaudeUsageFetcherError.cacheUnavailable
        }
    }

    static func runCaptureFromStandardInput() -> Int32 {
        let bridge = ClaudeStatusLineBridge()
        return bridge.captureAndForward()
    }

    private func captureAndForward() -> Int32 {
        guard let manifest = try? readManifest() else {
            return forwardFallbackFromEnvironment()
        }

        let shouldForward = manifest.originalCommand.map {
            !$0.isEmpty && $0 != manifest.installedCommand
        } ?? false
        let forwarder = shouldForward
            ? OriginalStatusLineProcess(command: manifest.originalCommand ?? "")
            : nil
        let input = readBoundedStandardInput(maximumBytes: Self.maximumInputBytes) { chunk in
            forwarder?.write(chunk)
        }
        forwarder?.closeInput()

        if !input.exceededLimit {
            try? SecureBridgeFiles.withExclusiveDirectoryLock(applicationSupportDirectory) {
                guard let currentManifest = try readManifestIfPresent(),
                      currentManifest.enabled,
                      currentManifest.installedCommand == manifest.installedCommand else { return }
                let previous = try SecureBridgeFiles.readIfPresent(
                    cacheURL,
                    maximumBytes: Self.maximumCacheBytes,
                    privacy: .privateFile
                )
                guard let filtered = try ClaudeStatusLineCacheParser.filteredCache(
                    from: input.data,
                    previousCache: previous?.data
                ) else { return }
                try SecureBridgeFiles.writeAtomic(
                    filtered,
                    to: cacheURL,
                    mode: 0o600,
                    expectedIdentity: previous?.identity
                )
            }
        }

        if shouldForward {
            return forwarder?.waitForExit() ?? 1
        }
        return 0
    }

    private struct SettingsFile {
        let object: [String: Any]
        let mode: mode_t
        let identity: SecureBridgeFiles.FileIdentity?
    }

    private struct BridgeManifest {
        var enabled: Bool
        let installedCommand: String
        let originalStatusLine: Any?
        let installedStatusLine: [String: Any]
        let originalCommand: String?
    }

    private func readSettings() throws -> SettingsFile {
        guard let file = try SecureBridgeFiles.readIfPresent(
            settingsURL,
            maximumBytes: Self.maximumSettingsBytes,
            privacy: .settingsFile
        ) else {
            return SettingsFile(object: [:], mode: 0o600, identity: nil)
        }
        guard let object = try JSONSerialization.jsonObject(with: file.data) as? [String: Any] else {
            throw ClaudeUsageFetcherError.settingsUnavailable
        }
        return SettingsFile(
            object: object,
            mode: file.identity.mode & 0o777,
            identity: file.identity
        )
    }

    private func writeSettings(
        _ object: [String: Any],
        mode: mode_t,
        expectedIdentity: SecureBridgeFiles.FileIdentity?
    ) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ClaudeUsageFetcherError.settingsUnavailable
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count + 1 <= Self.maximumSettingsBytes else {
            throw ClaudeUsageFetcherError.settingsUnavailable
        }
        try SecureBridgeFiles.writeAtomic(
            data + Data("\n".utf8),
            to: settingsURL,
            mode: mode,
            expectedIdentity: expectedIdentity
        )
    }

    private func readManifestIfPresent() throws -> BridgeManifest? {
        guard let file = try SecureBridgeFiles.readIfPresent(
            manifestURL,
            maximumBytes: Self.maximumManifestBytes,
            privacy: .privateFile
        ) else { return nil }
        return try Self.parseManifest(file.data)
    }

    private func readManifest() throws -> BridgeManifest {
        guard let manifest = try readManifestIfPresent() else {
            throw ClaudeUsageFetcherError.bridgeNotInstalled
        }
        return manifest
    }

    private func writeManifest(_ manifest: BridgeManifest) throws {
        var object: [String: Any] = [
            "schema_version": Self.manifestSchemaVersion,
            "capture_enabled": manifest.enabled,
            "installed_command": manifest.installedCommand,
            "installed_status_line": manifest.installedStatusLine,
            "had_original_status_line": manifest.originalStatusLine != nil
        ]
        if let originalStatusLine = manifest.originalStatusLine {
            object["original_status_line"] = originalStatusLine
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ClaudeUsageFetcherError.unsupportedStatusLine
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count + 1 <= Self.maximumManifestBytes else {
            throw ClaudeUsageFetcherError.unsupportedStatusLine
        }
        try SecureBridgeFiles.writeAtomic(
            data + Data("\n".utf8),
            to: manifestURL,
            mode: 0o600,
            expectedIdentity: SecureBridgeFiles.identityIfPresent(manifestURL)
        )
    }

    private static func parseManifest(_ data: Data) throws -> BridgeManifest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schema_version"] as? NSNumber,
              schema.intValue == manifestSchemaVersion,
              let enabled = object["capture_enabled"] as? Bool,
              let installedCommand = object["installed_command"] as? String,
              !installedCommand.isEmpty,
              installedCommand.count <= 16_384,
              let installedStatusLine = object["installed_status_line"] as? [String: Any],
              command(from: installedStatusLine) == installedCommand,
              let hadOriginal = object["had_original_status_line"] as? Bool else {
            throw ClaudeUsageFetcherError.bridgeNotInstalled
        }

        let originalStatusLine: Any?
        if hadOriginal {
            guard let value = object["original_status_line"] as? [String: Any],
                  value["type"] as? String == "command",
                  let originalCommand = command(from: value),
                  originalCommand.count <= 65_536 else {
                throw ClaudeUsageFetcherError.bridgeNotInstalled
            }
            originalStatusLine = value
        } else {
            originalStatusLine = nil
        }
        let originalCommand = command(from: originalStatusLine)
        if originalCommand?.count ?? 0 > 65_536 {
            throw ClaudeUsageFetcherError.bridgeNotInstalled
        }

        return BridgeManifest(
            enabled: enabled,
            installedCommand: installedCommand,
            originalStatusLine: originalStatusLine,
            installedStatusLine: installedStatusLine,
            originalCommand: originalCommand
        )
    }

    private func writeHelper(executableURL: URL, originalCommand: String?) throws {
        let app = Self.shellQuoted(executableURL.path)
        let manifest = Self.shellQuoted(manifestURL.path)
        let fallback = Self.shellQuoted(
            originalCommand.map { Data($0.utf8).base64EncodedString() } ?? ""
        )
        let script = """
        #!/bin/sh
        app=\(app)
        manifest=\(manifest)
        fallback=\(fallback)
        if [ -x "$app" ] && [ -r "$manifest" ]; then
          size=$(/usr/bin/stat -f '%z' "$manifest" 2>/dev/null)
          schema=$(/usr/bin/plutil -extract schema_version raw -o - "$manifest" 2>/dev/null)
          installed=$(/usr/bin/plutil -extract installed_command raw -o - "$manifest" 2>/dev/null)
          object_command=$(/usr/bin/plutil -extract installed_status_line.command raw -o - "$manifest" 2>/dev/null)
          object_type=$(/usr/bin/plutil -extract installed_status_line.type raw -o - "$manifest" 2>/dev/null)
          enabled=$(/usr/bin/plutil -extract capture_enabled raw -o - "$manifest" 2>/dev/null)
          had_original=$(/usr/bin/plutil -extract had_original_status_line raw -o - "$manifest" 2>/dev/null)
          original_command=$(/usr/bin/plutil -extract original_status_line.command raw -o - "$manifest" 2>/dev/null)
          original_type=$(/usr/bin/plutil -extract original_status_line.type raw -o - "$manifest" 2>/dev/null)
          case "$size" in
            ''|*[!0-9]*) valid=0 ;;
            *) [ "$size" -le \(Self.maximumManifestBytes) ] && [ "$schema" = "\(Self.manifestSchemaVersion)" ] && [ -n "$installed" ] && [ "$installed" = "$object_command" ] && [ "$object_type" = "command" ] && { [ "$enabled" = "true" ] || [ "$enabled" = "false" ]; } && { [ "$had_original" = "true" ] || [ "$had_original" = "false" ]; } && { [ "$had_original" = "false" ] || { [ "$original_type" = "command" ] && [ -n "$original_command" ]; }; } && valid=1 || valid=0 ;;
          esac
          if [ "$valid" -eq 1 ]; then
            CODEX_PULSE_STATUSLINE_FALLBACK_B64="$fallback" exec "$app" --claude-statusline-capture
          fi
        fi
        if [ -n "$fallback" ]; then
          original=$(printf '%s' "$fallback" | /usr/bin/base64 -D 2>/dev/null)
          exec /bin/sh -c "$original"
        fi
        exit 0
        """
        try SecureBridgeFiles.writeAtomic(
            Data(script.utf8),
            to: helperURL,
            mode: 0o700,
            expectedIdentity: SecureBridgeFiles.identityIfPresent(helperURL)
        )
    }

    private static func validatePreservableStatusLine(_ value: Any?) throws {
        guard let value else { return }
        guard let object = value as? [String: Any],
              let type = object["type"] as? String,
              type == "command",
              let command = object["command"] as? String,
              command.count <= 65_536 else {
            throw ClaudeUsageFetcherError.unsupportedStatusLine
        }
    }

    private static func command(from statusLine: Any?) -> String? {
        (statusLine as? [String: Any])?["command"] as? String
    }

    private static func type(from statusLine: Any?) -> String? {
        (statusLine as? [String: Any])?["type"] as? String
    }

    private static func jsonObjectsEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return (lhs as AnyObject).isEqual(rhs)
        default:
            return false
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func readBoundedStandardInput(
        maximumBytes: Int,
        onChunk: (Data) -> Void = { _ in }
    ) -> (data: Data, exceededLimit: Bool) {
        var data = Data()
        var exceeded = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(STDIN_FILENO, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                data.removeAll(keepingCapacity: false)
                exceeded = true
                break
            }
            let chunk = Data(buffer.prefix(count))
            onChunk(chunk)
            if !exceeded, chunk.count <= maximumBytes - data.count {
                data.append(chunk)
            } else {
                data.removeAll(keepingCapacity: false)
                exceeded = true
            }
        }
        return (data, exceeded)
    }

    private func drainStandardInput() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(STDIN_FILENO, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return }
            if count < 0, errno != EINTR { return }
        }
    }

    private func forwardFallbackFromEnvironment() -> Int32 {
        guard let encoded = ProcessInfo.processInfo.environment["CODEX_PULSE_STATUSLINE_FALLBACK_B64"],
              encoded.count <= 100_000,
              let data = Data(base64Encoded: encoded),
              data.count <= 65_536,
              let command = String(data: data, encoding: .utf8),
              !command.isEmpty else {
            drainStandardInput()
            return 0
        }
        guard let forwarder = OriginalStatusLineProcess(command: command) else {
            drainStandardInput()
            return 1
        }
        _ = readBoundedStandardInput(maximumBytes: Self.maximumInputBytes) { chunk in
            forwarder.write(chunk)
        }
        forwarder.closeInput()
        return forwarder.waitForExit()
    }
}

private final class OriginalStatusLineProcess {
    private let process = Process()
    private let inputPipe = Pipe()
    private var inputClosed = false
    private var inputFailed = false

    init?(command: String) {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CODEX_PULSE_STATUSLINE_FALLBACK_B64")
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            return nil
        }
    }

    func write(_ data: Data) {
        guard !inputClosed, !inputFailed else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            inputFailed = true
            closeInput()
        }
    }

    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        try? inputPipe.fileHandleForWriting.close()
    }

    func waitForExit() -> Int32 {
        closeInput()
        process.waitUntilExit()
        return process.terminationStatus
    }

    deinit {
        closeInput()
        if process.isRunning { process.terminate() }
    }
}

enum SecureBridgeFiles {
    enum Privacy {
        case settingsFile
        case privateFile
    }

    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let owner: uid_t
        let links: nlink_t
        let modifiedSeconds: time_t
        let modifiedNanoseconds: Int64
        let changedSeconds: time_t
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            mode = status.st_mode
            owner = status.st_uid
            links = status.st_nlink
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }

        func matchesVersion(_ other: FileIdentity) -> Bool {
            device == other.device
                && inode == other.inode
                && size == other.size
                && mode == other.mode
                && owner == other.owner
                && links == other.links
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    struct ReadResult {
        let data: Data
        let identity: FileIdentity
    }

    private enum FileError: Error {
        case unsafe
        case changed
        case io
    }

    static func ensureOwnedDirectory(_ url: URL, mode: mode_t) throws {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT,
                  url.path.withCString({ mkdir($0, mode) }) == 0 || errno == EEXIST else {
                throw FileError.io
            }
            guard url.path.withCString({ lstat($0, &status) }) == 0 else {
                throw FileError.io
            }
        }
        let prohibited = mode_t(S_IWGRP | S_IWOTH)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(),
              status.st_mode & prohibited == 0 else {
            throw FileError.unsafe
        }
    }

    static func validateOwnedDirectoryIfPresent(_ url: URL) throws -> Bool {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { return false }
            throw FileError.io
        }
        let prohibited = mode_t(S_IWGRP | S_IWOTH)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(),
              status.st_mode & prohibited == 0 else {
            throw FileError.unsafe
        }
        return true
    }

    static func withExclusiveDirectoryLock<T>(
        _ url: URL,
        body: () throws -> T
    ) throws -> T {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        }
        guard descriptor >= 0 else { throw FileError.io }
        defer { close(descriptor) }

        var status = stat()
        let prohibited = mode_t(S_IWGRP | S_IWOTH)
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(),
              status.st_mode & prohibited == 0 else {
            throw FileError.unsafe
        }

        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw FileError.io
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func readIfPresent(
        _ url: URL,
        maximumBytes: Int,
        privacy: Privacy
    ) throws -> ReadResult? {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw FileError.io
        }
        defer { close(descriptor) }

        var beforeStatus = stat()
        guard fstat(descriptor, &beforeStatus) == 0 else { throw FileError.io }
        let before = FileIdentity(beforeStatus)
        guard isSafeFile(before, privacy: privacy),
              before.size >= 0,
              before.size <= maximumBytes else {
            throw FileError.unsafe
        }

        var data = Data()
        data.reserveCapacity(Int(before.size))
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileError.io
            }
            guard data.count + count <= maximumBytes else { throw FileError.unsafe }
            data.append(buffer, count: count)
        }

        var afterStatus = stat()
        guard fstat(descriptor, &afterStatus) == 0,
              FileIdentity(afterStatus) == before else {
            throw FileError.changed
        }
        return ReadResult(data: data, identity: before)
    }

    static func identityIfPresent(_ url: URL) -> FileIdentity? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else { return nil }
        return FileIdentity(status)
    }

    static func isSafeExecutable(_ url: URL) -> Bool {
        guard let identity = identityIfPresent(url) else { return false }
        let prohibited = mode_t(S_ISUID | S_ISGID | S_IWGRP | S_IWOTH)
        return identity.mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && identity.mode & prohibited == 0
            && (identity.owner == getuid() || identity.owner == 0)
            && identity.links == 1
            && identity.mode & mode_t(S_IXUSR) != 0
            && identity.size > 0
    }

    static func writeAtomic(
        _ data: Data,
        to url: URL,
        mode: mode_t,
        expectedIdentity: FileIdentity?
    ) throws {
        let parent = url.deletingLastPathComponent()
        try ensureOwnedDirectory(parent, mode: 0o700)
        if let current = identityIfPresent(url) {
            guard current == expectedIdentity,
                  isSafeFile(current, privacy: .settingsFile) else {
                throw FileError.changed
            }
        } else if expectedIdentity != nil {
            throw FileError.changed
        }

        let directoryDescriptor = parent.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        }
        guard directoryDescriptor >= 0 else { throw FileError.io }
        defer { close(directoryDescriptor) }

        let temporaryName = ".codex-pulse-\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode
            )
        }
        guard descriptor >= 0 else { throw FileError.io }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FileError.io
                }
                offset += count
            }
        }
        guard fchmod(descriptor, mode) == 0,
              fsync(descriptor) == 0 else {
            throw FileError.io
        }
        var desiredStatus = stat()
        guard fstat(descriptor, &desiredStatus) == 0 else { throw FileError.io }
        let desiredIdentity = FileIdentity(desiredStatus)

        if let current = identityIfPresent(url) {
            guard current == expectedIdentity else { throw FileError.changed }
        } else if expectedIdentity != nil {
            throw FileError.changed
        }

        if let expectedIdentity {
            let swapResult = temporaryName.withCString { temporary in
                url.lastPathComponent.withCString { destination in
                    renameatx_np(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapResult == 0 else { throw FileError.io }
            shouldRemoveTemporary = false
            guard let displacedIdentity = identityIfPresent(
                    parent.appendingPathComponent(temporaryName, isDirectory: false)
                  ) else { throw FileError.io }

            if !displacedIdentity.matchesVersion(expectedIdentity) {
                var candidateIdentity = displacedIdentity
                var placedIdentity = desiredIdentity
                while true {
                    let rollbackResult = temporaryName.withCString { temporary in
                        url.lastPathComponent.withCString { destination in
                            renameatx_np(
                                directoryDescriptor,
                                temporary,
                                directoryDescriptor,
                                destination,
                                UInt32(RENAME_SWAP)
                            )
                        }
                    }
                    guard rollbackResult == 0,
                          let newlyDisplaced = identityIfPresent(
                            parent.appendingPathComponent(temporaryName, isDirectory: false)
                          ) else {
                        throw FileError.io
                    }
                    if newlyDisplaced.matchesVersion(placedIdentity) {
                        temporaryName.withCString {
                            _ = unlinkat(directoryDescriptor, $0, 0)
                        }
                        _ = fsync(directoryDescriptor)
                        throw FileError.changed
                    }
                    placedIdentity = candidateIdentity
                    candidateIdentity = newlyDisplaced
                }
            }
            guard let installedIdentity = identityIfPresent(url),
                  installedIdentity.matchesVersion(desiredIdentity) else {
                throw FileError.changed
            }
            temporaryName.withCString {
                _ = unlinkat(directoryDescriptor, $0, 0)
            }
        } else {
            let renameResult = temporaryName.withCString { temporary in
                url.lastPathComponent.withCString { destination in
                    renameatx_np(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameResult == 0 else { throw FileError.changed }
            shouldRemoveTemporary = false
        }
        _ = fsync(directoryDescriptor)
    }

    static func removeOwnedRegularFile(_ url: URL) throws {
        guard let identity = identityIfPresent(url) else { return }
        guard isSafeFile(identity, privacy: .settingsFile) else {
            throw FileError.unsafe
        }
        guard url.path.withCString({ unlink($0) }) == 0 || errno == ENOENT else {
            throw FileError.io
        }
    }

    private static func isSafeFile(_ identity: FileIdentity, privacy: Privacy) -> Bool {
        let commonProhibited = mode_t(S_ISUID | S_ISGID | S_IWGRP | S_IWOTH)
        guard identity.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              identity.mode & commonProhibited == 0,
              identity.owner == getuid(),
              identity.links == 1 else {
            return false
        }
        if privacy == .privateFile {
            return identity.mode & 0o077 == 0
        }
        return true
    }
}
