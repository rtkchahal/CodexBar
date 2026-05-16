import XCTest
@testable import CodexBarCore

final class FoundryMonitorFetcherTests: XCTestCase {
    private let sampleResourceId = "/subscriptions/sub-123/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/acct"

    func test_monthWindow_returnsStartOfMonthAndNextMonth() {
        let now = ISO8601DateFormatter().date(from: "2026-05-16T12:00:00Z")!
        let window = FoundryMonitorFetcher.monthWindow(for: now)
        let cal = Calendar(identifier: .gregorian)
        let startComponents = cal.dateComponents([.year, .month, .day], from: window.start)
        XCTAssertEqual(startComponents.day, 1)
        XCTAssertEqual(window.end, now)
        XCTAssertTrue(window.reset > window.start)
    }

    func test_buildMetricsURL_includesExpectedQueryItems() throws {
        let start = ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-05-16T12:00:00Z")!
        let url = try FoundryMonitorFetcher.buildMetricsURL(resourceId: self.sampleResourceId, start: start, end: end)
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://management.azure.com/subscriptions/sub-123/"))
        XCTAssertTrue(absolute.contains("metricnames=ProcessedPromptTokens"))
        XCTAssertTrue(absolute.contains("GeneratedCompletionTokens"))
        XCTAssertTrue(absolute.contains("aggregation=Total"))
        XCTAssertTrue(absolute.contains("api-version=\(FoundryMonitorFetcher.apiVersion)"))
    }

    func test_parseReport_sumsTotalsAcrossTimeseries() throws {
        let payload: [String: Any] = [
            "value": [
                [
                    "name": ["value": "InputTokens"],
                    "timeseries": [
                        ["data": [["total": 100.0], ["total": 50.0]]],
                        ["data": [["total": 25.0]]],
                    ],
                ],
                [
                    "name": ["value": "OutputTokens"],
                    "timeseries": [["data": [["total": 200.0]]]],
                ],
                [
                    "name": ["value": "TotalTokens"],
                    "timeseries": [["data": [["total": 375.0]]]],
                ],
                [
                    "name": ["value": "ModelRequests"],
                    "timeseries": [["data": [["total": 40.0]]]],
                ],
                [
                    "name": ["value": "AzureOpenAIRequests"],
                    "timeseries": [["data": [["total": 7.0]]]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let reset = end.addingTimeInterval(86_400)
        let report = try FoundryMonitorFetcher.parseReport(
            data: data,
            resourceId: self.sampleResourceId,
            start: start,
            end: end,
            monthReset: reset)
        XCTAssertEqual(report.inputTokens, 175.0)
        XCTAssertEqual(report.outputTokens, 200.0)
        XCTAssertEqual(report.totalTokens, 375.0)
        XCTAssertEqual(report.modelRequests, 40.0)
        XCTAssertEqual(report.azureOpenAIRequests, 7.0)
        XCTAssertEqual(report.totalRequests, 47.0)
        XCTAssertEqual(report.windowStart, start)
        XCTAssertEqual(report.windowEnd, end)
    }

    func test_fetchReport_returnsParsedReportOnSuccess() async throws {
        let payload: [String: Any] = [
            "value": [[
                "name": ["value": "InputTokens"],
                "timeseries": [["data": [["total": 12.0]]]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let runtime = FoundryMonitorRuntime(
            azPath: { "/usr/local/bin/az" },
            fetchAccessToken: { "stub-token" },
            performRequest: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (http, data)
            })
        let report = try await FoundryMonitorFetcher.fetchReport(
            resourceId: self.sampleResourceId,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            runtime: runtime)
        XCTAssertEqual(report.inputTokens, 12.0)
    }

    func test_fetchReport_throwsMissingAZCLIWhenPathUnavailable() async {
        let runtime = FoundryMonitorRuntime(
            azPath: { nil },
            fetchAccessToken: { "should not be called" },
            performRequest: { _ in throw URLError(.badURL) })
        do {
            _ = try await FoundryMonitorFetcher.fetchReport(resourceId: self.sampleResourceId, runtime: runtime)
            XCTFail("Expected missingAZCLI error")
        } catch let error as FoundryMonitorError {
            if case .missingAZCLI = error { return }
            XCTFail("Wrong error: \(error)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_fetchReport_throwsRequestFailedOnNon200() async {
        let runtime = FoundryMonitorRuntime(
            azPath: { "/usr/local/bin/az" },
            fetchAccessToken: { "token" },
            performRequest: { request in
                let http = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                return (http, Data("AuthorizationFailed".utf8))
            })
        do {
            _ = try await FoundryMonitorFetcher.fetchReport(resourceId: self.sampleResourceId, runtime: runtime)
            XCTFail("Expected requestFailed")
        } catch let error as FoundryMonitorError {
            if case let .requestFailed(status, body) = error {
                XCTAssertEqual(status, 403)
                XCTAssertEqual(body, "AuthorizationFailed")
                return
            }
            XCTFail("Wrong error: \(error)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test_fetchReport_throwsNoResourceForEmptyId() async {
        let runtime = FoundryMonitorRuntime(
            azPath: { "/usr/local/bin/az" },
            fetchAccessToken: { "token" },
            performRequest: { _ in throw URLError(.badURL) })
        do {
            _ = try await FoundryMonitorFetcher.fetchReport(resourceId: "", runtime: runtime)
            XCTFail("Expected noResource")
        } catch let error as FoundryMonitorError {
            if case .noResource = error { return }
            XCTFail("Wrong error: \(error)")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
