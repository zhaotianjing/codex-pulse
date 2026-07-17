import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: UsageConnectionState = .connecting
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var claudeSnapshot: ClaudeUsageSnapshot?
    @Published private(set) var claudeState: ClaudeMonitoringState
    @Published private(set) var lastClaudeUpdated: Date?
    @Published private(set) var isClaudeMonitoringEnabled: Bool
    @Published private(set) var isRefreshing = false

    private let fetcher: CodexUsageFetching
    private let claudeFetcher = ClaudeUsageFetcher()
    private let defaults: UserDefaults
    private var timer: Timer?
    private var pendingRefreshes = 0
    private var codexGeneration = 0
    private var claudeGeneration = 0
    private var isStopped = false

    private static let claudeMonitoringDefaultsKey = "claudeStatusLineMonitoringEnabledV2"
    private static let claudeCleanupWarningDefaultsKey = "claudeStatusLineCleanupWarningV2"

    init(
        defaults: UserDefaults = .standard,
        fetcher: CodexUsageFetching = CodexUsageFetcher()
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        let enabled = defaults.bool(forKey: Self.claudeMonitoringDefaultsKey)
        isClaudeMonitoringEnabled = enabled
        if enabled {
            claudeState = .connecting
        } else if let warning = defaults.string(forKey: Self.claudeCleanupWarningDefaultsKey) {
            claudeState = .failed(warning)
        } else {
            claudeState = .disabled
        }
    }

    func start() {
        isStopped = false
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isStopped = true
        codexGeneration += 1
        claudeGeneration += 1
        fetcher.cancelAndWait()
        claudeFetcher.cancel()
        pendingRefreshes = 0
        isRefreshing = false
    }

    func refresh() {
        guard !isStopped, !isRefreshing else { return }
        isRefreshing = true
        pendingRefreshes = isClaudeMonitoringEnabled ? 2 : 1
        if snapshot == nil { state = .connecting }
        if isClaudeMonitoringEnabled, claudeSnapshot == nil { claudeState = .connecting }

        let generation = codexGeneration
        fetcher.fetch { [weak self] result in
            guard let self else { return }
            guard !self.isStopped, self.codexGeneration == generation else { return }

            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.lastUpdated = Date()
                self.state = .live
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
            self.finishOneRefresh()
        }

        guard isClaudeMonitoringEnabled else { return }
        startClaudeFetch(countsTowardRefresh: true)
    }

    func enableClaudeMonitoring() {
        guard !isClaudeMonitoringEnabled else { return }
        claudeState = .connecting

        do {
            try claudeFetcher.installSynchronously()
        } catch {
            claudeState = .failed(error.localizedDescription)
            return
        }

        defaults.set(true, forKey: Self.claudeMonitoringDefaultsKey)
        defaults.removeObject(forKey: Self.claudeCleanupWarningDefaultsKey)
        claudeGeneration += 1
        isClaudeMonitoringEnabled = true

        if isRefreshing {
            pendingRefreshes += 1
            startClaudeFetch(countsTowardRefresh: true)
        } else {
            refresh()
        }
    }

    func disableClaudeMonitoring() {
        claudeGeneration += 1
        let cleanupError: Error?
        do {
            try claudeFetcher.uninstallSynchronously()
            cleanupError = nil
        } catch {
            cleanupError = error
        }

        defaults.set(false, forKey: Self.claudeMonitoringDefaultsKey)
        isClaudeMonitoringEnabled = false
        claudeFetcher.cancel()
        claudeSnapshot = nil
        lastClaudeUpdated = nil
        if let cleanupError {
            let message = cleanupError.localizedDescription
            defaults.set(message, forKey: Self.claudeCleanupWarningDefaultsKey)
            claudeState = .failed(message)
        } else {
            defaults.removeObject(forKey: Self.claudeCleanupWarningDefaultsKey)
            claudeState = .disabled
        }
    }

    private func startClaudeFetch(countsTowardRefresh: Bool) {
        let generation = claudeGeneration
        claudeFetcher.fetch { [weak self] result in
            guard let self else { return }
            guard !self.isStopped,
                  self.isClaudeMonitoringEnabled,
                  self.claudeGeneration == generation else {
                if countsTowardRefresh { self.finishOneRefresh() }
                return
            }

            switch result {
            case .success(let snapshot):
                self.claudeSnapshot = snapshot
                self.lastClaudeUpdated = snapshot.fetchedAt
                self.claudeState = .live
            case .failure(let error):
                self.claudeState = .failed(error.localizedDescription)
            }
            if countsTowardRefresh { self.finishOneRefresh() }
        }
    }

    private func finishOneRefresh() {
        pendingRefreshes = max(0, pendingRefreshes - 1)
        if pendingRefreshes == 0 {
            isRefreshing = false
        }
    }
}
