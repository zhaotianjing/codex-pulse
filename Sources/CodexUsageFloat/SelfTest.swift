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

            print(passed ? "Self-test passed" : "Self-test failed: unexpected parsed values")
            return passed
        } catch {
            print("Self-test failed: \(error.localizedDescription)")
            return false
        }
    }
}
