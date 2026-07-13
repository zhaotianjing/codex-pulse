import AppKit

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

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
MainActor.assumeIsolated {
    application.delegate = delegate
}
application.run()
