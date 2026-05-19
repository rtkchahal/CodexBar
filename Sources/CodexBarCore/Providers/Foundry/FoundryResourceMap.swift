import Foundation

/// Maps Foundry provider keys to Azure ARM resource ids so the Monitor
/// strategy knows which resource to query. V1 stores the mapping in env
/// vars: `CODEXBAR_FOUNDRY_RESOURCE_<PROVIDER_KEY_UPPER>`.
public enum FoundryResourceMap {
    public static let envVarPrefix = "CODEXBAR_FOUNDRY_RESOURCE_"

    /// Returns the ARM resource id configured for a given provider key, or
    /// nil if the user has not wired Azure Monitor for that key.
    public static func resourceId(
        for providerKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let canonical = providerKey.uppercased().replacingOccurrences(of: "-", with: "_")
        guard let raw = environment[self.envVarPrefix + canonical]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }

    /// All distinct (providerKey, resourceId) pairs that are configured.
    public static func configuredResources(
        for deployments: [FoundryDeployment],
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [(providerKey: String, resourceId: String)]
    {
        var seen: Set<String> = []
        var pairs: [(String, String)] = []
        for deployment in deployments {
            guard let resourceId = self.resourceId(for: deployment.providerKey, environment: environment) else { continue }
            let key = "\(deployment.providerKey)|\(resourceId)"
            if seen.insert(key).inserted {
                pairs.append((deployment.providerKey, resourceId))
            }
        }
        return pairs
    }
}
