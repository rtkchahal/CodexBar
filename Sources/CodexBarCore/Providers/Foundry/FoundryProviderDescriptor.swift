import CodexBarMacroSupport
import Foundation
import OSLog

private let foundryLog = Logger(subsystem: "com.steipete.codexbar", category: "foundry")

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum FoundryProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .foundry,
            metadata: ProviderMetadata(
                id: .foundry,
                displayName: "Azure AI Foundry",
                sessionLabel: "Deployments",
                weeklyLabel: "Status",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Azure AI Foundry deployments",
                cliName: "foundry",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://ai.azure.com/",
                statusPageURL: nil,
                statusLinkURL: "https://azure.status.microsoft/en-us/status"),
            branding: ProviderBranding(
                iconStyle: .foundry,
                iconResourceName: "ProviderIcon-foundry",
                color: ProviderColor(red: 0 / 255, green: 120 / 255, blue: 212 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "No Foundry deployments discovered. Configure OpenClaw or add manual deployments." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [
                    FoundryMonitorFetchStrategy(),
                    FoundryProbeFetchStrategy(),
                    FoundryDiscoveryFetchStrategy(),
                ] })),
            cli: ProviderCLIConfig(
                name: "foundry",
                aliases: ["azure-foundry"],
                versionDetector: nil))
    }
}

/// Phase 1 strategy: only enumerates discovered deployments. No network calls.
struct FoundryDiscoveryFetchStrategy: ProviderFetchStrategy {
    let id: String = "foundry.discovery"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        !FoundrySettingsReader.discoverDeployments(environment: context.env).isEmpty
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let deployments = FoundrySettingsReader.discoverDeployments(environment: context.env)
        let snapshot = FoundryUsageSnapshot(deployments: deployments, updatedAt: Date())
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "discovery")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

/// Phase 3 strategy: aggregates Azure Monitor MTD token + request counts
/// for any deployment whose provider key has a resource id mapped via
/// `CODEXBAR_FOUNDRY_RESOURCE_<PROVIDER>` env vars. Falls back to probe
/// strategy when Azure Monitor is not configured or the `az` CLI is
/// unavailable.
struct FoundryMonitorFetchStrategy: ProviderFetchStrategy {
    let id: String = "foundry.monitor"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let deployments = FoundrySettingsReader.discoverDeployments(environment: context.env)
        return !FoundryResourceMap.configuredResources(for: deployments, environment: context.env).isEmpty
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let deployments = FoundrySettingsReader.discoverDeployments(environment: context.env)
        let resources = FoundryResourceMap.configuredResources(for: deployments, environment: context.env)

        foundryLog.info("Foundry monitor fetch: \(resources.count, privacy: .public) resources configured")
        let reports: [FoundryMonitorReport] = await withTaskGroup(of: FoundryMonitorReport?.self) { group in
            for pair in resources {
                group.addTask {
                    do {
                        let report = try await FoundryMonitorFetcher.fetchReport(resourceId: pair.resourceId)
                        foundryLog.info("Foundry monitor OK provider=\(pair.providerKey, privacy: .public) total=\(report.totalTokens ?? 0, privacy: .public)")
                        return report
                    } catch {
                        foundryLog.error("Foundry monitor FAIL provider=\(pair.providerKey, privacy: .public) error=\(String(describing: error), privacy: .public)")
                        return nil
                    }
                }
            }
            var collected: [FoundryMonitorReport] = []
            for await report in group {
                if let report { collected.append(report) }
            }
            return collected
        }

        // Best-effort: also include probes if any keys are set so the card
        // can still surface per-deployment health alongside MTD totals.
        let probes = await Self.probeIfPossible(deployments: deployments, environment: context.env)

        let snapshot = FoundryUsageSnapshot(
            deployments: deployments,
            probes: probes.map(FoundryDeploymentProbeResultSnapshot.init),
            monitorReports: reports,
            updatedAt: Date())
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "monitor")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        true
    }

    private static func probeIfPossible(
        deployments: [FoundryDeployment],
        environment: [String: String]) async -> [FoundryDeploymentProbeResult]
    {
        let probeable = deployments.filter {
            FoundryProbeFetcher.lookupAPIKey(for: $0, environment: environment) != nil
        }
        guard !probeable.isEmpty else { return [] }
        return await withTaskGroup(of: FoundryDeploymentProbeResult.self) { group in
            for deployment in probeable {
                group.addTask {
                    await FoundryProbeFetcher.probe(deployment: deployment, environment: environment)
                }
            }
            var results: [FoundryDeploymentProbeResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
}

/// Phase 2 strategy: probes each discovered deployment for reachability +
/// rate-limit hints. Requires `CODEXBAR_FOUNDRY_KEY_<PROVIDER>` env vars; if
/// no probe yields data the descriptor falls back to ``FoundryDiscoveryFetchStrategy``.
struct FoundryProbeFetchStrategy: ProviderFetchStrategy {
    let id: String = "foundry.probe"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let deployments = FoundrySettingsReader.discoverDeployments(environment: context.env)
        guard !deployments.isEmpty else { return false }
        // Available iff at least one provider-key has a key configured.
        for deployment in deployments {
            if FoundryProbeFetcher.lookupAPIKey(for: deployment, environment: context.env) != nil {
                return true
            }
        }
        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let deployments = FoundrySettingsReader.discoverDeployments(environment: context.env)
        let env = context.env

        let probes = await withTaskGroup(of: FoundryDeploymentProbeResult.self) { group in
            for deployment in deployments {
                group.addTask {
                    await FoundryProbeFetcher.probe(deployment: deployment, environment: env)
                }
            }
            var results: [FoundryDeploymentProbeResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let snapshot = FoundryUsageSnapshot(
            deployments: deployments,
            probes: probes.map(FoundryDeploymentProbeResultSnapshot.init),
            updatedAt: Date())
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "probe")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        true
    }
}
