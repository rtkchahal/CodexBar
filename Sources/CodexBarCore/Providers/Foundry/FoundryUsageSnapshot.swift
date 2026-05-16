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
        // Probes mean different things per endpoint shape. Anthropic-style
        // Foundry endpoints (anthropic-foundry) don't expose `/models`, so
        // probes return 404 and are noise. Only surface probe ratios when at
        // least one probe in the group succeeded.
        let summaryParts = groups
            .map { key, list -> String in
                let groupProbes = self.probes.filter { $0.providerKey == key }
                let okCount = groupProbes.filter { $0.status == "ok" }.count
                if okCount > 0 {
                    return "\(key): \(okCount)/\(list.count) ok"
                }
                return "\(key): \(list.count)"
            }
            .sorted()

        var loginParts = summaryParts
        var extras: [NamedRateWindow] = []

        if let rollup = self.rollup {
            // Foundry is consumption-billed — no caps, no resets. Pack raw
            // counters into `resetDescription`; the MenuCardView Foundry
            // branch reads that as `statusText` and skips the progress bar.
            extras.append(Self.makeWindow(id: "foundry.today", title: "Today (UTC)", totals: rollup.today))
            extras.append(Self.makeWindow(id: "foundry.week", title: "Last 7 days", totals: rollup.week))
            extras.append(Self.makeWindow(id: "foundry.month", title: "Month-to-date", totals: rollup.month))

            // Per-deployment MTD breakdown, sorted by total tokens descending.
            let perDeployment = rollup.perDeploymentMTD
                .sorted { $0.value.totalTokens > $1.value.totalTokens }
            for (deployment, totals) in perDeployment where totals.totalTokens > 0 {
                extras.append(Self.makeWindow(
                    id: "foundry.dep.\(deployment)",
                    title: deployment,
                    totals: totals))
            }

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
        totals: FoundryWindowTotals) -> NamedRateWindow
    {
        let input = Int(totals.inputTokens)
        let output = Int(totals.outputTokens)
        let req = Int(totals.modelRequests)
        // No reset date — Foundry doesn't have one. The branch in MenuCardView
        // routes `resetDescription` to `statusText` to bypass the bar.
        let description = "In \(self.formattedTokenCount(input)) · Out \(self.formattedTokenCount(output)) · \(req) req"
        return NamedRateWindow(
            id: id,
            title: title,
            window: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
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
