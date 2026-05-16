import Foundation

/// Aggregated, provider-group level Foundry view.
///
/// Phase 1 surfaced discovery counts. Phase 2 layers in per-deployment probe
/// results so the menu card can show reachability and rate-limit hints.
public struct FoundryUsageSnapshot: Codable, Sendable {
    public let deployments: [FoundryDeployment]
    public let providerGroupCount: Int
    public let probes: [FoundryDeploymentProbeResultSnapshot]
    public let monitorReports: [FoundryMonitorReport]
    public let rollup: FoundryUsageRollup?
    public let updatedAt: Date

    public init(
        deployments: [FoundryDeployment],
        probes: [FoundryDeploymentProbeResultSnapshot] = [],
        monitorReports: [FoundryMonitorReport] = [],
        updatedAt: Date)
    {
        self.deployments = deployments
        self.providerGroupCount = Set(deployments.map(\.providerKey)).count
        self.probes = probes
        self.monitorReports = monitorReports
        self.updatedAt = updatedAt
        if monitorReports.isEmpty {
            self.rollup = nil
        } else {
            let allBuckets = monitorReports.flatMap(\.dailyBuckets)
            let reset = monitorReports.first?.monthResetAt ?? updatedAt
            self.rollup = FoundryUsageRollup.from(
                buckets: allBuckets,
                now: updatedAt,
                monthResetAt: reset)
        }
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

        var loginParts = summaryParts
        var extras: [NamedRateWindow] = []

        if let rollup = self.rollup {
            // Render three "windows" with usedPercent=0 (no cap on consumption
            // billing) but expressive reset descriptions so the UI shows the
            // real counters without the misleading 100%-left bar.
            let now = self.updatedAt
            extras.append(Self.makeWindow(
                id: "foundry.today",
                title: "Today",
                totals: rollup.today,
                reset: Calendar(identifier: .gregorian).startOfDay(for: Date(timeInterval: 86_400, since: now))))
            extras.append(Self.makeWindow(
                id: "foundry.week",
                title: "7-day",
                totals: rollup.week,
                reset: nil))
            extras.append(Self.makeWindow(
                id: "foundry.month",
                title: "Month",
                totals: rollup.month,
                reset: rollup.monthResetAt))

            let totalMTD = Int(rollup.month.totalTokens)
            let reqMTD = Int(rollup.month.modelRequests)
            if totalMTD > 0 {
                loginParts.append("MTD: \(Self.formattedTokenCount(totalMTD)) tokens")
            }
            if reqMTD > 0 {
                loginParts.append("\(reqMTD) req")
            }
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .foundry,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginParts.isEmpty ? "no deployments discovered" : loginParts.joined(separator: " · "))

        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: extras.isEmpty ? nil : extras,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private static func makeWindow(
        id: String,
        title: String,
        totals: FoundryWindowTotals,
        reset: Date?) -> NamedRateWindow
    {
        let input = Int(totals.inputTokens)
        let output = Int(totals.outputTokens)
        let req = Int(totals.modelRequests)
        let description = "In \(self.formattedTokenCount(input)) · Out \(self.formattedTokenCount(output)) · \(req) req"
        return NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: reset,
                resetDescription: description))
    }

    static func formattedTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}
