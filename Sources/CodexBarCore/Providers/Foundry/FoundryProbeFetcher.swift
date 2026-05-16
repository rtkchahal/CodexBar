import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-deployment Foundry health probe. Does a single GET against the
/// deployment's base URL and captures `x-ratelimit-*` headers when present.
///
/// V1 goals (Phase 2):
/// - Confirm the deployment is reachable with the configured API key
/// - Surface a status enum (`ok`, `unauthorized`, `notFound`, `throttled`, `network`)
/// - Never log or persist raw keys
public struct FoundryDeploymentProbeResult: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ok
        case unauthorized
        case notFound
        case throttled
        case serverError
        case network
        case missingKey
    }

    public let deploymentId: String
    public let providerKey: String
    public let status: Status
    public let httpStatus: Int?
    public let limitRequests: String?
    public let limitTokens: String?
    public let remainingRequests: String?
    public let remainingTokens: String?
    public let resetAt: Date?

    public init(
        deploymentId: String,
        providerKey: String,
        status: Status,
        httpStatus: Int?,
        limitRequests: String? = nil,
        limitTokens: String? = nil,
        remainingRequests: String? = nil,
        remainingTokens: String? = nil,
        resetAt: Date? = nil)
    {
        self.deploymentId = deploymentId
        self.providerKey = providerKey
        self.status = status
        self.httpStatus = httpStatus
        self.limitRequests = limitRequests
        self.limitTokens = limitTokens
        self.remainingRequests = remainingRequests
        self.remainingTokens = remainingTokens
        self.resetAt = resetAt
    }
}

public enum FoundryProbeFetcher {
    public static let envVarKeyPrefix = "CODEXBAR_FOUNDRY_KEY_"

    /// Probes a single deployment. The API key is looked up from the
    /// environment via `CODEXBAR_FOUNDRY_KEY_<PROVIDER_KEY_UPPER>` (e.g.
    /// `CODEXBAR_FOUNDRY_KEY_ANTHROPIC_FOUNDRY`). Returns `.missingKey`
    /// without making a network call when the key is unset.
    public static func probe(
        deployment: FoundryDeployment,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared,
        timeout: TimeInterval = 4) async -> FoundryDeploymentProbeResult
    {
        guard let url = self.probeURL(for: deployment) else {
            return FoundryDeploymentProbeResult(
                deploymentId: deployment.deploymentId,
                providerKey: deployment.providerKey,
                status: .network,
                httpStatus: nil)
        }

        guard let apiKey = self.lookupAPIKey(for: deployment, environment: environment) else {
            return FoundryDeploymentProbeResult(
                deploymentId: deployment.deploymentId,
                providerKey: deployment.providerKey,
                status: .missingKey,
                httpStatus: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar/foundry-probe", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return FoundryDeploymentProbeResult(
                    deploymentId: deployment.deploymentId,
                    providerKey: deployment.providerKey,
                    status: .network,
                    httpStatus: nil)
            }
            return self.makeResult(from: http, deployment: deployment)
        } catch {
            return FoundryDeploymentProbeResult(
                deploymentId: deployment.deploymentId,
                providerKey: deployment.providerKey,
                status: .network,
                httpStatus: nil)
        }
    }

    static func probeURL(for deployment: FoundryDeployment) -> URL? {
        let trimmed = deployment.baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        let path: String
        if normalized.contains("/openai") || deployment.api.lowercased().contains("openai") {
            path = "/models?api-version=2024-10-21"
        } else if normalized.contains("/v1") {
            path = "/models"
        } else {
            // Default to AOAI-style management probe (idempotent, cheap).
            path = "/openai/models?api-version=2024-10-21"
        }
        return URL(string: normalized + path)
    }

    static func lookupAPIKey(
        for deployment: FoundryDeployment,
        environment: [String: String]) -> String?
    {
        let canonical = deployment.providerKey
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        let key = self.envVarKeyPrefix + canonical
        if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return nil
    }

    static func makeResult(
        from http: HTTPURLResponse,
        deployment: FoundryDeployment) -> FoundryDeploymentProbeResult
    {
        let status: FoundryDeploymentProbeResult.Status = switch http.statusCode {
        case 200 ..< 300: .ok
        case 401, 403: .unauthorized
        case 404: .notFound
        case 429: .throttled
        case 500 ..< 600: .serverError
        default: .network
        }

        return FoundryDeploymentProbeResult(
            deploymentId: deployment.deploymentId,
            providerKey: deployment.providerKey,
            status: status,
            httpStatus: http.statusCode,
            limitRequests: self.header(http, "x-ratelimit-limit-requests"),
            limitTokens: self.header(http, "x-ratelimit-limit-tokens"),
            remainingRequests: self.header(http, "x-ratelimit-remaining-requests"),
            remainingTokens: self.header(http, "x-ratelimit-remaining-tokens"),
            resetAt: self.parseResetHeader(http))
    }

    private static func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        if let value = response.value(forHTTPHeaderField: name) {
            return value
        }
        for (key, value) in response.allHeaderFields {
            if let keyString = key as? String, keyString.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    private static func parseResetHeader(_ response: HTTPURLResponse) -> Date? {
        let candidates = [
            "x-ratelimit-reset-requests",
            "x-ratelimit-reset-tokens",
            "retry-after",
        ]
        for name in candidates {
            guard let raw = self.header(response, name)?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { continue }
            if let seconds = TimeInterval(raw) {
                return Date().addingTimeInterval(seconds)
            }
        }
        return nil
    }
}
