import Foundation

/// Aggregated, provider-group level Foundry view.
///
/// Phase 1 surfaced discovery counts. Phase 2 layers in per-deployment probe
/// results so the menu card can show reachability and rate-limit hints.
public struct FoundryUsageSnapshot: Codable, Sendable {
    public let deployments: [FoundryDeployment]
    public let providerGroupCount: Int
    public let probes: [FoundryDeploymentProbeResultSnapshot]
    public let updatedAt: Date

    public init(
        deployments: [FoundryDeployment],
        probes: [FoundryDeploymentProbeResultSnapshot] = [],
        updatedAt: Date)
    {
        self.deployments = deployments
        self.providerGroupCount = Set(deployments.map(\.providerKey)).count
        self.probes = probes
        self.updatedAt = updatedAt
    }
}

/// Codable mirror of ``FoundryDeploymentProbeResult`` for persistence.
public struct FoundryDeploymentProbeResultSnapshot: Codable, Sendable, Equatable {
    public let deploymentId: String
    public let providerKey: String
    public let status: String
    public let httpStatus: Int?
    public let limitRequests: String?
    public let limitTokens: String?
    public let remainingRequests: String?
    public let remainingTokens: String?
    public let resetAt: Date?

    public init(_ probe: FoundryDeploymentProbeResult) {
        self.deploymentId = probe.deploymentId
        self.providerKey = probe.providerKey
        self.status = probe.status.rawValue
        self.httpStatus = probe.httpStatus
        self.limitRequests = probe.limitRequests
        self.limitTokens = probe.limitTokens
        self.remainingRequests = probe.remainingRequests
        self.remainingTokens = probe.remainingTokens
        self.resetAt = probe.resetAt
    }
}

extension FoundryUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let groups = Dictionary(grouping: self.deployments, by: \.providerKey)
        let summaryParts = groups
            .map { key, list -> String in
                let groupProbes = self.probes.filter { $0.providerKey == key }
                let okCount = groupProbes.filter { $0.status == "ok" }.count
                if groupProbes.isEmpty {
                    return "\(key): \(list.count)"
                }
                return "\(key): \(okCount)/\(list.count) ok"
            }
            .sorted()

        let identity = ProviderIdentitySnapshot(
            providerID: .foundry,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: summaryParts.isEmpty ? "no deployments discovered" : summaryParts.joined(separator: " · "))

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
