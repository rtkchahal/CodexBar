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
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [FoundryDiscoveryFetchStrategy()] })),
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
