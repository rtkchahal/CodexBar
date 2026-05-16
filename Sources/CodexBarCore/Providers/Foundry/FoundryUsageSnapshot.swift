import Foundation

/// Aggregated, provider-group level Foundry view (V1: counts only, no usage).
public struct FoundryUsageSnapshot: Codable, Sendable {
    public let deployments: [FoundryDeployment]
    public let providerGroupCount: Int
    public let updatedAt: Date

    public init(deployments: [FoundryDeployment], updatedAt: Date) {
        self.deployments = deployments
        self.providerGroupCount = Set(deployments.map(\.providerKey)).count
        self.updatedAt = updatedAt
    }
}

extension FoundryUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let groups = Dictionary(grouping: self.deployments, by: \.providerKey)
        let summary = groups
            .map { key, list in "\(key): \(list.count)" }
            .sorted()
            .joined(separator: " · ")

        let identity = ProviderIdentitySnapshot(
            providerID: .foundry,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: summary.isEmpty ? "no deployments discovered" : summary)

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
