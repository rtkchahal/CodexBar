import Foundation

/// Discovers Azure AI Foundry deployments from OpenClaw's ``models.json`` files
/// and merges them with any manually configured deployments.
///
/// V1 only handles auto-discovery; manual entries are a stub for Phase 2/3.
public enum FoundrySettingsReader {
    public static let agentDirEnvKey = "OPENCLAW_AGENT_DIR"
    public static let modelsJSONOverrideKey = "CODEXBAR_FOUNDRY_MODELS_JSON"

    /// Provider keys we consider "Azure AI Foundry deployments". Kept tight so
    /// generic `openai`/`anthropic` keys don't get pulled in.
    public static let foundryProviderKeys: Set<String> = [
        "anthropic-foundry",
        "kimi-foundry",
        "pmi-foundry-project",
        "pmi-openai",
        "azure-kimi",
        "azure-openai",
        "azure-openai-gpt4o",
        "azure-openai-o1",
        "azure-openai-o1-mini",
        "azure-openai-o3-mini",
        "microsoft-foundry",
    ]

    /// Returns deployments parsed from any reachable ``models.json``. Always
    /// returns an array (empty on parse failure) so callers never have to
    /// special-case "discovery failed".
    public static func discoverDeployments(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> [FoundryDeployment]
    {
        let paths = self.modelsJSONCandidatePaths(environment: environment, fileManager: fileManager)

        var seen: Set<String> = []
        var results: [FoundryDeployment] = []

        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            for deployment in self.parseDeployments(from: data, source: "openclaw-models.json") {
                if seen.insert(deployment.id).inserted {
                    results.append(deployment)
                }
            }
        }

        return results
    }

    /// Exposed for testing.
    static func parseDeployments(from data: Data, source: String) -> [FoundryDeployment] {
        guard
            let top = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let providers = top["providers"] as? [String: Any]
        else { return [] }

        var deployments: [FoundryDeployment] = []
        for (providerKey, raw) in providers {
            guard self.foundryProviderKeys.contains(providerKey) else { continue }
            guard let providerDict = raw as? [String: Any] else { continue }

            let baseURL = (providerDict["baseUrl"] as? String) ?? (providerDict["baseURL"] as? String) ?? ""
            let auth = (providerDict["auth"] as? String) ?? "api-key"
            let providerAPI = (providerDict["api"] as? String) ?? ""

            let models = providerDict["models"] as? [[String: Any]] ?? []
            for model in models {
                guard let modelID = (model["id"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !modelID.isEmpty else { continue }
                let displayName = (model["name"] as? String) ?? modelID
                let api = (model["api"] as? String) ?? providerAPI

                deployments.append(FoundryDeployment(
                    providerKey: providerKey,
                    deploymentId: modelID,
                    displayName: displayName,
                    baseURL: baseURL,
                    api: api,
                    auth: auth,
                    source: source))
            }
        }
        // Stable order: provider key then deployment id.
        return deployments.sorted { lhs, rhs in
            if lhs.providerKey == rhs.providerKey {
                return lhs.deploymentId < rhs.deploymentId
            }
            return lhs.providerKey < rhs.providerKey
        }
    }

    /// Candidate paths to look at, in priority order.
    static func modelsJSONCandidatePaths(
        environment: [String: String],
        fileManager: FileManager) -> [String]
    {
        var candidates: [String] = []

        if let override = self.cleaned(environment[self.modelsJSONOverrideKey]) {
            candidates.append(override)
        }

        if let agentDir = self.cleaned(environment[self.agentDirEnvKey]) {
            candidates.append((agentDir as NSString).appendingPathComponent("models.json"))
            candidates.append((agentDir as NSString).appendingPathComponent("agent/models.json"))
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let agentsRoot = (home as NSString).appendingPathComponent(".openclaw/agents")
        if let contents = try? fileManager.contentsOfDirectory(atPath: agentsRoot) {
            for entry in contents.sorted() {
                let candidate = (agentsRoot as NSString)
                    .appendingPathComponent(entry)
                    .appending("/agent/models.json")
                candidates.append(candidate)
            }
        }

        // Deduplicate while preserving order; only keep existing files.
        var seen: Set<String> = []
        return candidates.filter { path in
            guard seen.insert(path).inserted else { return false }
            return fileManager.fileExists(atPath: path)
        }
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
