import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: UsageConnectionState = .connecting
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    private let fetcher = CodexUsageFetcher()
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if snapshot == nil { state = .connecting }

        fetcher.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false

            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.lastUpdated = Date()
                self.state = .live
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}
