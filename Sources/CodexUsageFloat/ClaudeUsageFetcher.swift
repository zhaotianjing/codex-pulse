import CoreFoundation
import Foundation

struct ClaudeUsageSnapshot: Equatable {
    let limits: [ClaudeRateLimit]
    let fetchedAt: Date
    let isStale: Bool

    var sessionLimit: ClaudeRateLimit? {
        limits.first(where: { $0.kind == .session })
    }

    var weeklyLimit: ClaudeRateLimit? {
        limits.first(where: { $0.kind == .weeklyAll })
    }
}

struct ClaudeRateLimit: Identifiable, Equatable {
    enum Kind: Equatable {
        case session
        case weeklyAll
    }

    let id: String
    let kind: Kind
    let name: String
    let usedPercent: Double
    let resetsAt: Date
    let capturedAt: Date
}

enum ClaudeMonitoringState: Equatable {
    case disabled
    case connecting
    case live
    case failed(String)
}

enum ClaudeUsageFetcherError: LocalizedError, Equatable {
    case bridgeNotInstalled
    case settingsUnavailable
    case unsupportedStatusLine
    case cleanupConflict
    case awaitingClaudeResponse
    case cacheUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .bridgeNotInstalled:
            return "Claude monitoring is not connected. Disable it, then enable it again."
        case .settingsUnavailable:
            return "Claude settings could not be updated safely. Check ~/.claude/settings.json and try again."
        case .unsupportedStatusLine:
            return "The existing Claude status line could not be preserved safely."
        case .cleanupConflict:
            return "Claude monitoring stopped, but the status line changed after setup. Its new setting was left untouched."
        case .awaitingClaudeResponse:
            return "Waiting for Claude usage. Send one normal prompt in Claude Code, then refresh."
        case .cacheUnavailable:
            return "Claude has not supplied a usable rate-limit snapshot yet."
        case .invalidResponse:
            return "Claude supplied unexpected rate-limit data. Update Claude Code and try again."
        }
    }
}

enum ClaudeStatusLineCacheParser {
    static let schemaVersion = 1
    static let recentInterval: TimeInterval = 10 * 60
    private static let maximumAge: TimeInterval = 8 * 24 * 60 * 60
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60
    private static let maximumResetInterval: TimeInterval = 8 * 24 * 60 * 60

    static func parse(data: Data, now: Date = Date()) throws -> ClaudeUsageSnapshot {
        guard data.count <= ClaudeStatusLineBridge.maximumCacheBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(object["schema_version"]) == schemaVersion else {
            throw ClaudeUsageFetcherError.invalidResponse
        }

        var limits: [ClaudeRateLimit] = []
        if let limit = parseWindow(
            object["five_hour"],
            id: "session",
            kind: .session,
            name: "Current session",
            now: now
        ) {
            limits.append(limit)
        }
        if let limit = parseWindow(
            object["seven_day"],
            id: "weekly-all",
            kind: .weeklyAll,
            name: "Current week (all models)",
            now: now
        ) {
            limits.append(limit)
        }

        guard !limits.isEmpty else {
            throw ClaudeUsageFetcherError.cacheUnavailable
        }

        let fetchedAt = limits.map(\.capturedAt).max() ?? now
        let isStale = limits.contains { now.timeIntervalSince($0.capturedAt) > recentInterval }
        return ClaudeUsageSnapshot(limits: limits, fetchedAt: fetchedAt, isStale: isStale)
    }

    static func filteredCache(
        from statusLineData: Data,
        previousCache: Data?,
        capturedAt: Date = Date()
    ) throws -> Data? {
        guard statusLineData.count <= ClaudeStatusLineBridge.maximumInputBytes,
              let root = try JSONSerialization.jsonObject(with: statusLineData) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else {
            return nil
        }

        var cache: [String: Any] = ["schema_version": schemaVersion]
        if let previousCache,
           previousCache.count <= ClaudeStatusLineBridge.maximumCacheBytes,
           let previous = try? JSONSerialization.jsonObject(with: previousCache) as? [String: Any],
           integer(previous["schema_version"]) == schemaVersion {
            for key in ["five_hour", "seven_day"] {
                if let value = sanitizedCachedWindow(previous[key], now: capturedAt) {
                    cache[key] = value
                }
            }
        }

        var capturedAny = false
        for key in ["five_hour", "seven_day"] {
            guard let value = sanitizedStatusLineWindow(rateLimits[key], capturedAt: capturedAt) else {
                continue
            }
            cache[key] = value
            capturedAny = true
        }

        guard capturedAny else { return nil }
        return try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
    }

    private static func parseWindow(
        _ rawValue: Any?,
        id: String,
        kind: ClaudeRateLimit.Kind,
        name: String,
        now: Date
    ) -> ClaudeRateLimit? {
        guard let value = rawValue as? [String: Any],
              let usedPercent = finiteNumber(value["used_percentage"]),
              (0...100).contains(usedPercent),
              let resetsAtSeconds = finiteNumber(value["resets_at"]),
              let capturedAtSeconds = finiteNumber(value["captured_at"]) else {
            return nil
        }

        let resetsAt = Date(timeIntervalSince1970: resetsAtSeconds)
        let capturedAt = Date(timeIntervalSince1970: capturedAtSeconds)
        let age = now.timeIntervalSince(capturedAt)
        let resetDistance = resetsAt.timeIntervalSince(capturedAt)
        guard capturedAtSeconds > 0,
              resetsAtSeconds > 0,
              age >= -maximumFutureClockSkew,
              age <= maximumAge,
              resetDistance >= -maximumFutureClockSkew,
              resetDistance <= maximumResetInterval,
              resetsAt > now else {
            return nil
        }

        return ClaudeRateLimit(
            id: id,
            kind: kind,
            name: name,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            capturedAt: capturedAt
        )
    }

    private static func sanitizedStatusLineWindow(_ rawValue: Any?, capturedAt: Date) -> [String: Any]? {
        guard let value = rawValue as? [String: Any],
              let usedPercent = finiteNumber(value["used_percentage"]),
              (0...100).contains(usedPercent),
              let resetsAt = finiteNumber(value["resets_at"]),
              resetsAt > 0,
              resetsAt - capturedAt.timeIntervalSince1970 >= -maximumFutureClockSkew,
              resetsAt - capturedAt.timeIntervalSince1970 <= maximumResetInterval else {
            return nil
        }

        return [
            "used_percentage": usedPercent,
            "resets_at": resetsAt,
            "captured_at": capturedAt.timeIntervalSince1970
        ]
    }

    private static func sanitizedCachedWindow(_ rawValue: Any?, now: Date) -> [String: Any]? {
        guard let value = rawValue as? [String: Any],
              let usedPercent = finiteNumber(value["used_percentage"]),
              (0...100).contains(usedPercent),
              let resetsAt = finiteNumber(value["resets_at"]),
              let capturedAt = finiteNumber(value["captured_at"]),
              capturedAt > 0,
              resetsAt > now.timeIntervalSince1970,
              now.timeIntervalSince1970 - capturedAt <= maximumAge else {
            return nil
        }
        return [
            "used_percentage": usedPercent,
            "resets_at": resetsAt,
            "captured_at": capturedAt
        ]
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }
}

final class ClaudeUsageFetcher {
    private let worker = DispatchQueue(label: "com.codexpulse.claude-fetch", qos: .utility)
    private let bridge: ClaudeStatusLineBridge

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL? = Bundle.main.executableURL
    ) {
        bridge = ClaudeStatusLineBridge(homeDirectory: homeDirectory, executableURL: executableURL)
    }

    func installSynchronously() throws {
        try bridge.install()
    }

    func uninstallSynchronously() throws {
        try bridge.uninstall()
    }

    func fetch(completion: @escaping (Result<ClaudeUsageSnapshot, Error>) -> Void) {
        worker.async {
            let result = Result { try self.fetchSynchronously() }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func cancel() {}

    func fetchSynchronously() throws -> ClaudeUsageSnapshot {
        try bridge.readSnapshot()
    }
}
