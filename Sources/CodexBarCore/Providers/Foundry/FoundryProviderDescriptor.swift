import CodexBarMacroSupport
import Foundation

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
