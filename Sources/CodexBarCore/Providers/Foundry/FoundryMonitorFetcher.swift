import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Azure Monitor metrics fetch for Foundry deployments (Phase 3, opt-in).
///
/// Authenticates via `az account get-access-token` (no separate login in
/// CodexBar). Calls Azure Monitor metrics REST API for token + request
/// counters scoped to a Cognitive Services account resource.
public struct FoundryMonitorReport: Sendable, Equatable, Codable {
    public let resourceId: String
    public let processedPromptTokens: Double?
    public let generatedCompletionTokens: Double?
    public let processedInferenceTokens: Double?
    public let azureOpenAIRequests: Double?
    public let windowStart: Date
    public let windowEnd: Date
    public let monthResetAt: Date

    public init(
        resourceId: String,
        processedPromptTokens: Double?,
        generatedCompletionTokens: Double?,
        processedInferenceTokens: Double?,
        azureOpenAIRequests: Double?,
        windowStart: Date,
        windowEnd: Date,
        monthResetAt: Date)
    {
        self.resourceId = resourceId
        self.processedPromptTokens = processedPromptTokens
        self.generatedCompletionTokens = generatedCompletionTokens
        self.processedInferenceTokens = processedInferenceTokens
        self.azureOpenAIRequests = azureOpenAIRequests
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.monthResetAt = monthResetAt
    }
}

public enum FoundryMonitorError: LocalizedError, Sendable {
    case missingAZCLI
    case authFailed(String)
    case requestFailed(Int, String?)
    case decodeFailed(String)
    case noResource

    public var errorDescription: String? {
        switch self {
        case .missingAZCLI:
            "Azure CLI (`az`) is not on PATH. Install from https://aka.ms/azcli."
        case let .authFailed(message):
            "Azure auth failed: \(message). Run `az login`."
        case let .requestFailed(status, body):
            "Azure Monitor request failed (\(status)): \(body ?? "no body")"
        case let .decodeFailed(message):
            "Failed to decode Azure Monitor response: \(message)"
        case .noResource:
            "No Azure resource id configured for this deployment."
        }
    }
}

/// Abstraction layer so unit tests can supply fake `az` + HTTP responses.
public struct FoundryMonitorRuntime: Sendable {
    public var azPath: @Sendable () -> String?
    public var fetchAccessToken: @Sendable () async throws -> String
    public var performRequest: @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)

    public init(
        azPath: @escaping @Sendable () -> String?,
        fetchAccessToken: @escaping @Sendable () async throws -> String,
        performRequest: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))
    {
        self.azPath = azPath
        self.fetchAccessToken = fetchAccessToken
        self.performRequest = performRequest
    }

    public static let production = FoundryMonitorRuntime(
        azPath: {
            let candidates = ["/usr/local/bin/az", "/opt/homebrew/bin/az", "/usr/bin/az"]
            for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            return nil
        },
        fetchAccessToken: {
            try await FoundryMonitorFetcher.runAZForToken()
        },
        performRequest: { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FoundryMonitorError.requestFailed(0, "Non-HTTP response")
            }
            return (http, data)
        })
}

public enum FoundryMonitorFetcher {
    public static let resourceManagementBase = "https://management.azure.com"
    public static let apiVersion = "2024-02-01"

    /// Fetches month-to-date totals for the given resource. Resource id must
    /// be the full ARM id, e.g.
    /// `/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>`.
    public static func fetchReport(
        resourceId: String,
        now: Date = Date(),
        runtime: FoundryMonitorRuntime = .production) async throws -> FoundryMonitorReport
    {
        guard !resourceId.isEmpty else { throw FoundryMonitorError.noResource }
        guard runtime.azPath() != nil else { throw FoundryMonitorError.missingAZCLI }

        let (start, end, reset) = self.monthWindow(for: now)
        let token = try await runtime.fetchAccessToken()
        let url = try self.buildMetricsURL(resourceId: resourceId, start: start, end: end)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (response, data) = try await runtime.performRequest(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw FoundryMonitorError.requestFailed(response.statusCode, body)
        }

        return try self.parseReport(data: data, resourceId: resourceId, start: start, end: end, monthReset: reset)
    }

    static func monthWindow(for now: Date) -> (start: Date, end: Date, reset: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? now
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return (start, now, nextMonth)
    }

    static func buildMetricsURL(resourceId: String, start: Date, end: Date) throws -> URL {
        let trimmed = resourceId.hasPrefix("/") ? String(resourceId.dropFirst()) : resourceId
        var components = URLComponents(string: "\(self.resourceManagementBase)/\(trimmed)/providers/Microsoft.Insights/metrics")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let metrics = [
            "ProcessedPromptTokens",
            "GeneratedCompletionTokens",
            "ProcessedInferenceTokens",
            "AzureOpenAIRequests",
        ].joined(separator: ",")
        components?.queryItems = [
            URLQueryItem(name: "api-version", value: self.apiVersion),
            URLQueryItem(name: "metricnames", value: metrics),
            URLQueryItem(name: "aggregation", value: "Total"),
            URLQueryItem(name: "timespan", value: "\(formatter.string(from: start))/\(formatter.string(from: end))"),
        ]
        guard let url = components?.url else {
            throw FoundryMonitorError.decodeFailed("Failed to build metrics URL")
        }
        return url
    }

    static func parseReport(
        data: Data,
        resourceId: String,
        start: Date,
        end: Date,
        monthReset: Date) throws -> FoundryMonitorReport
    {
        guard let top = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw FoundryMonitorError.decodeFailed("Top-level JSON not an object")
        }
        let values = (top["value"] as? [[String: Any]]) ?? []

        var totals: [String: Double] = [:]
        for entry in values {
            guard let name = (entry["name"] as? [String: Any])?["value"] as? String else { continue }
            let timeseries = entry["timeseries"] as? [[String: Any]] ?? []
            var sum = 0.0
            for series in timeseries {
                let datapoints = series["data"] as? [[String: Any]] ?? []
                for point in datapoints {
                    if let total = point["total"] as? Double {
                        sum += total
                    }
                }
            }
            totals[name] = sum
        }

        return FoundryMonitorReport(
            resourceId: resourceId,
            processedPromptTokens: totals["ProcessedPromptTokens"],
            generatedCompletionTokens: totals["GeneratedCompletionTokens"],
            processedInferenceTokens: totals["ProcessedInferenceTokens"],
            azureOpenAIRequests: totals["AzureOpenAIRequests"],
            windowStart: start,
            windowEnd: end,
            monthResetAt: monthReset)
    }

    // Shells out to `az account get-access-token --resource https://management.azure.com`.
    static func runAZForToken() async throws -> String {
        let candidates = ["/usr/local/bin/az", "/opt/homebrew/bin/az", "/usr/bin/az"]
        let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let path else { throw FoundryMonitorError.missingAZCLI }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [
            "account", "get-access-token",
            "--resource", "https://management.azure.com",
            "--output", "json",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw FoundryMonitorError.authFailed("failed to spawn az: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errString = String(data: errData, encoding: .utf8) ?? ""
            throw FoundryMonitorError.authFailed(errString)
        }
        guard let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty
        else {
            throw FoundryMonitorError.authFailed("missing accessToken in az output")
        }
        return token
    }
}
