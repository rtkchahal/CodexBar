import XCTest
@testable import CodexBarCore

final class FoundryUsageRollupTests: XCTestCase {
    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal
    }()

    private func day(_ offset: Int, from now: Date) -> Date {
        self.utcCalendar.date(byAdding: .day, value: offset, to: self.utcCalendar.startOfDay(for: now))!
    }

    private func bucket(day: Int, from now: Date, deployment: String, input: Double, output: Double, req: Double) -> FoundryDailyBucket {
        FoundryDailyBucket(
            date: self.day(day, from: now),
            deployment: deployment,
            inputTokens: input,
            outputTokens: output,
            modelRequests: req)
    }

    func test_rollup_groupsBucketsIntoTodayWeekMonth() {
        let now = ISO8601DateFormatter().date(from: "2026-05-16T15:30:00Z")!
        let buckets: [FoundryDailyBucket] = [
            // Today
            self.bucket(day: 0, from: now, deployment: "claude-opus-4-7", input: 1000, output: 200, req: 5),
            self.bucket(day: 0, from: now, deployment: "gpt-5.5-1", input: 500, output: 50, req: 3),
            // Yesterday (still in week + month)
            self.bucket(day: -1, from: now, deployment: "claude-opus-4-7", input: 2000, output: 400, req: 10),
            // 5 days ago (in week + month)
            self.bucket(day: -5, from: now, deployment: "claude-opus-4-7", input: 4000, output: 800, req: 20),
            // 10 days ago (in month but outside 7d week)
            self.bucket(day: -10, from: now, deployment: "claude-opus-4-7", input: 8000, output: 1600, req: 40),
        ]
        let reset = self.utcCalendar.date(from: self.utcCalendar.dateComponents([.year, .month], from: self.utcCalendar.date(byAdding: .month, value: 1, to: now)!))!
        let rollup = FoundryUsageRollup.from(buckets: buckets, now: now, monthResetAt: reset, calendar: self.utcCalendar)

        XCTAssertEqual(rollup.today.inputTokens, 1500)
        XCTAssertEqual(rollup.today.outputTokens, 250)
        XCTAssertEqual(rollup.today.modelRequests, 8)

        XCTAssertEqual(rollup.week.inputTokens, 7000) // 1500 + 2000 + 4000 - wait, today=1500, -1=2000, -5=4000 → 7500
        // recompute: today buckets total input = 1000+500=1500. -1 day = 2000. -5 day = 4000. Sum = 7500.
        XCTAssertEqual(rollup.week.inputTokens, 7500)
        XCTAssertEqual(rollup.week.modelRequests, 38) // 8 + 10 + 20

        XCTAssertEqual(rollup.month.inputTokens, 15500) // 7500 + 8000
        XCTAssertEqual(rollup.month.modelRequests, 78)

        XCTAssertEqual(rollup.perDeploymentMTD["claude-opus-4-7"]?.inputTokens, 15000)
        XCTAssertEqual(rollup.perDeploymentMTD["gpt-5.5-1"]?.inputTokens, 500)
    }

    func test_rollup_emptyBucketsReturnsZeros() {
        let now = Date()
        let rollup = FoundryUsageRollup.from(buckets: [], now: now, monthResetAt: now, calendar: self.utcCalendar)
        XCTAssertEqual(rollup.today, .zero)
        XCTAssertEqual(rollup.week, .zero)
        XCTAssertEqual(rollup.month, .zero)
        XCTAssertTrue(rollup.perDeploymentMTD.isEmpty)
    }

    func test_extractDeploymentName_parsesMetadataValues() {
        let series: [String: Any] = [
            "metadatavalues": [
                ["name": ["value": "ModelDeploymentName"], "value": "claude-opus-4-7"],
            ],
        ]
        XCTAssertEqual(FoundryMonitorFetcher.extractDeploymentName(from: series), "claude-opus-4-7")
    }

    func test_extractDeploymentName_returnsNilWithoutMetadata() {
        XCTAssertNil(FoundryMonitorFetcher.extractDeploymentName(from: [:]))
    }

    func test_buildMetricsURL_includesDimensionFilter() throws {
        let start = ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-05-16T12:00:00Z")!
        let url = try FoundryMonitorFetcher.buildMetricsURL(
            resourceId: "/subscriptions/x/resourceGroups/y/providers/Microsoft.CognitiveServices/accounts/z",
            start: start,
            end: end)
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.contains("interval=P1D"))
        XCTAssertTrue(absolute.contains("ModelDeploymentName"))
    }
}
