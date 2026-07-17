import AppKit

if CommandLine.arguments.contains("--claude-statusline-capture") {
    exit(ClaudeStatusLineBridge.runCaptureFromStandardInput())
}

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--fetch-once") {
    do {
        let snapshot = try CodexUsageFetcher().fetchSynchronously()
        let primary = snapshot.primaryBucket?.usedPercent ?? 0
        print("Live fetch passed: plan=\(snapshot.planType ?? "unknown"), limits=\(snapshot.buckets.count), primaryUsed=\(primary)%")
        exit(0)
    } catch {
        print("Live fetch failed: \(error.localizedDescription)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--fetch-claude-once") {
    do {
        let snapshot = try ClaudeUsageFetcher().fetchSynchronously()
        guard !snapshot.isStale else {
            throw ClaudeUsageFetcherError.cacheUnavailable
        }
        let session = snapshot.sessionLimit.map { "\($0.usedPercent)%" } ?? "unavailable"
        let weekly = snapshot.weeklyLimit.map { "\($0.usedPercent)%" } ?? "unavailable"
        print("Claude fetch passed: limits=\(snapshot.limits.count), sessionUsed=\(session), weeklyUsed=\(weekly), cached=\(snapshot.isStale)")
        exit(0)
    } catch {
        print("Claude fetch failed: \(error.localizedDescription)")
        exit(1)
    }
}

let instanceLock: ApplicationInstanceLock
do {
    instanceLock = try ApplicationInstanceLock()
} catch ApplicationInstanceLockError.alreadyRunning {
    let bundleIdentifier = "io.github.zhaotianjing.codex-pulse"
    let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { $0.processIdentifier != currentProcessIdentifier })?
        .activate(options: [.activateAllWindows])
    exit(0)
} catch {
    fputs("Codex Pulse could not acquire its single-instance lock.\n", stderr)
    exit(1)
}

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    application.delegate = delegate
}
application.run()
withExtendedLifetime(instanceLock) {}
