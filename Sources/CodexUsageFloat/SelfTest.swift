import Darwin
import Foundation

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
            let passed = snapshot.planType == "pro"
                && snapshot.buckets.map(\.id) == ["codex", "spark"]
                && snapshot.primaryBucket?.remainingPercent == 88
                && snapshot.lifetimeTokens == 123_456
                && snapshot.dailyUsage.first?.tokens == 321
                && snapshot.resetCredits == 1
                && securityHelpersPass()

            print(passed ? "Self-test passed" : "Self-test failed: unexpected parsed values")
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
}
