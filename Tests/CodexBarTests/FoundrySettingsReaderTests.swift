import XCTest
@testable import CodexBarCore

final class FoundrySettingsReaderTests: XCTestCase {
    private let modelsJSONFixture: String = """
    {
      "providers": {
        "anthropic-foundry": {
          "baseUrl": "https://example.services.ai.azure.com/v1",
          "apiKey": "REDACTED",
          "auth": "api-key",
          "api": "anthropic-messages",
          "models": [
            {"id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5"},
            {"id": "claude-opus-4-7", "name": "Claude Opus 4.7"}
          ]
        },
        "pmi-openai": {
          "baseUrl": "https://example2.openai.azure.com/v1",
          "apiKey": "REDACTED",
          "auth": "api-key",
          "api": "openai-completions",
          "models": [
            {"id": "gpt-5.4-pro", "name": "GPT 5.4 Pro"}
          ]
        },
        "anthropic": {
          "baseUrl": "https://api.anthropic.com",
          "apiKey": "sk-ant-REDACTED",
          "auth": "oauth",
          "api": "anthropic-messages",
          "models": [
            {"id": "claude-sonnet-4-5", "name": "Claude Sonnet"}
          ]
        }
      }
    }
    """

    func test_parseDeployments_picksOnlyFoundryProviderKeys() throws {
        let data = self.modelsJSONFixture.data(using: .utf8)!
        let deployments = FoundrySettingsReader.parseDeployments(from: data, source: "fixture")
        XCTAssertEqual(deployments.count, 3)
        let ids = deployments.map(\.id).sorted()
        XCTAssertEqual(ids, [
            "anthropic-foundry/claude-opus-4-7",
            "anthropic-foundry/claude-sonnet-4-5",
            "pmi-openai/gpt-5.4-pro",
        ])
        XCTAssertFalse(ids.contains(where: { $0.hasPrefix("anthropic/") }),
                       "Generic anthropic provider must be filtered out")
    }

    func test_parseDeployments_preservesEndpointAndAuth() throws {
        let data = self.modelsJSONFixture.data(using: .utf8)!
        let deployments = FoundrySettingsReader.parseDeployments(from: data, source: "fixture")
        let opus = try XCTUnwrap(deployments.first(where: { $0.deploymentId == "claude-opus-4-7" }))
        XCTAssertEqual(opus.baseURL, "https://example.services.ai.azure.com/v1")
        XCTAssertEqual(opus.auth, "api-key")
        XCTAssertEqual(opus.api, "anthropic-messages")
        XCTAssertEqual(opus.providerKey, "anthropic-foundry")
        XCTAssertEqual(opus.source, "fixture")
        XCTAssertEqual(opus.host, "example.services.ai.azure.com")
    }

    func test_parseDeployments_handlesMalformedJSONSafely() {
        let bad = "{not json".data(using: .utf8)!
        XCTAssertEqual(FoundrySettingsReader.parseDeployments(from: bad, source: "fixture").count, 0)
    }

    func test_parseDeployments_emptyProviders() {
        let empty = #"{"providers": {}}"#.data(using: .utf8)!
        XCTAssertEqual(FoundrySettingsReader.parseDeployments(from: empty, source: "fixture").count, 0)
    }

    func test_snapshot_summaryGroupsByProvider() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deployments = [
            FoundryDeployment(providerKey: "anthropic-foundry", deploymentId: "claude-opus", displayName: "Opus",
                              baseURL: "https://a", api: "anthropic-messages", auth: "api-key", source: "test"),
            FoundryDeployment(providerKey: "anthropic-foundry", deploymentId: "claude-sonnet", displayName: "Sonnet",
                              baseURL: "https://a", api: "anthropic-messages", auth: "api-key", source: "test"),
            FoundryDeployment(providerKey: "pmi-openai", deploymentId: "gpt-5.4-pro", displayName: "GPT",
                              baseURL: "https://b", api: "openai-completions", auth: "api-key", source: "test"),
        ]
        let snapshot = FoundryUsageSnapshot(deployments: deployments, updatedAt: now)
        XCTAssertEqual(snapshot.providerGroupCount, 2)
        let usage = snapshot.toUsageSnapshot()
        let login = usage.identity?.loginMethod ?? ""
        XCTAssertTrue(login.contains("anthropic-foundry: 2"))
        XCTAssertTrue(login.contains("pmi-openai: 1"))
    }
}
