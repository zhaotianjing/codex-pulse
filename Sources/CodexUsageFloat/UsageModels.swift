import Foundation

struct UsageSnapshot: Equatable {
    var planType: String?
    var buckets: [RateLimitBucket]
    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var dailyUsage: [DailyUsage]
    var resetCredits: Int

    var primaryBucket: RateLimitBucket? {
        buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }

    var additionalBuckets: [RateLimitBucket] {
        guard let primaryBucket else { return buckets }
        return buckets.filter { $0.id != primaryBucket.id }
    }
}

struct RateLimitBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct DailyUsage: Identifiable, Equatable {
    var id: String { startDate }
    let startDate: String
    let tokens: Int64
}

enum UsageConnectionState: Equatable {
    case connecting
    case live
    case failed(String)
}

enum UsageParseError: LocalizedError {
    case missingRateLimits

    var errorDescription: String? {
        switch self {
        case .missingRateLimits:
            return "Codex 没有返回额度数据"
        }
    }
}

enum UsageResponseParser {
    static func parse(responses: [Int: [String: Any]]) throws -> UsageSnapshot {
        guard let rateResult = responses[3]?["result"] as? [String: Any] else {
            throw UsageParseError.missingRateLimits
        }

        var buckets: [RateLimitBucket] = []
        if let mapped = rateResult["rateLimitsByLimitId"] as? [String: Any] {
            for (key, value) in mapped {
                guard let snapshot = value as? [String: Any],
                      let bucket = parseBucket(snapshot, fallbackID: key) else { continue }
                buckets.append(bucket)
            }
        }

        if buckets.isEmpty,
           let snapshot = rateResult["rateLimits"] as? [String: Any],
           let bucket = parseBucket(snapshot, fallbackID: "codex") {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw UsageParseError.missingRateLimits
        }

        buckets.sort { lhs, rhs in
            if lhs.id == "codex" { return true }
            if rhs.id == "codex" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let usageResult = responses[4]?["result"] as? [String: Any]
        let summary = usageResult?["summary"] as? [String: Any]
        let lifetime = int64(summary?["lifetimeTokens"])
        let peak = int64(summary?["peakDailyTokens"])

        let dailyValues = usageResult?["dailyUsageBuckets"] as? [[String: Any]] ?? []
        let dailyUsage = dailyValues.compactMap { item -> DailyUsage? in
            guard let date = item["startDate"] as? String,
                  let tokens = int64(item["tokens"]) else { return nil }
            return DailyUsage(startDate: date, tokens: tokens)
        }

        let credits = rateResult["rateLimitResetCredits"] as? [String: Any]
        let creditCount = Int(int64(credits?["availableCount"]) ?? 0)
        let planFromLimit = (rateResult["rateLimits"] as? [String: Any])?["planType"] as? String

        return UsageSnapshot(
            planType: planFromLimit,
            buckets: buckets,
            lifetimeTokens: lifetime,
            peakDailyTokens: peak,
            dailyUsage: dailyUsage,
            resetCredits: creditCount
        )
    }

    private static func parseBucket(_ value: [String: Any], fallbackID: String) -> RateLimitBucket? {
        guard let primary = value["primary"] as? [String: Any],
              let used = double(primary["usedPercent"]) else { return nil }

        let id = (value["limitId"] as? String) ?? fallbackID
        let rawName = (value["limitName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (rawName?.isEmpty == false ? rawName : nil) ?? (id == "codex" ? "Codex" : id)
        let duration = int64(primary["windowDurationMins"]).map(Int.init)
        let resetTimestamp = double(primary["resetsAt"]).map { Date(timeIntervalSince1970: $0) }

        return RateLimitBucket(
            id: id,
            name: name,
            usedPercent: max(0, min(100, used)),
            windowDurationMinutes: duration,
            resetsAt: resetTimestamp
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
