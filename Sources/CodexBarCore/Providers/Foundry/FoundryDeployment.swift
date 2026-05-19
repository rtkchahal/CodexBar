import Foundation

/// A single Azure AI Foundry deployment discovered or configured for monitoring.
public struct FoundryDeployment: Codable, Sendable, Hashable, Identifiable {
    public let providerKey: String
    public let deploymentId: String
    public let displayName: String
    public let baseURL: String
    public let api: String
    public let auth: String
    /// Source of this entry: "openclaw-models.json" or "manual".
    public let source: String

    public var id: String { "\(self.providerKey)/\(self.deploymentId)" }

    public init(
        providerKey: String,
        deploymentId: String,
        displayName: String,
        baseURL: String,
        api: String,
        auth: String,
        source: String)
    {
        self.providerKey = providerKey
        self.deploymentId = deploymentId
        self.displayName = displayName
        self.baseURL = baseURL
        self.api = api
        self.auth = auth
        self.source = source
    }
}

extension FoundryDeployment {
    /// Best-effort host name extracted from `baseURL`, for UI rendering.
    public var host: String {
        guard let url = URL(string: self.baseURL), let host = url.host else {
            return self.baseURL
        }
        return host
    }
}
