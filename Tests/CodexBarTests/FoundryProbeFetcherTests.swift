import XCTest
@testable import CodexBarCore

final class FoundryProbeFetcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FoundryProbeStubURLProtocol.handler = nil
        FoundryProbeStubURLProtocol.requests = []
    }

    override func tearDown() {
        FoundryProbeStubURLProtocol.handler = nil
        FoundryProbeStubURLProtocol.requests = []
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FoundryProbeStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeDeployment(
        providerKey: String = "anthropic-foundry",
        baseURL: String = "https://example.services.ai.azure.com/v1",
        api: String = "anthropic-messages") -> FoundryDeployment
    {
        FoundryDeployment(
            providerKey: providerKey,
            deploymentId: "claude-opus-4-7",
            displayName: "Claude Opus 4.7",
            baseURL: baseURL,
            api: api,
            auth: "api-key",
            source: "test")
    }

    func test_probeURL_appendsModelsForV1Endpoint() throws {
        let deployment = self.makeDeployment(baseURL: "https://x.services.ai.azure.com/v1")
        let url = try XCTUnwrap(FoundryProbeFetcher.probeURL(for: deployment))
        XCTAssertEqual(url.absoluteString, "https://x.services.ai.azure.com/v1/models")
    }

    func test_probeURL_appendsAOAIPathWhenNoSuffix() throws {
        let deployment = self.makeDeployment(baseURL: "https://x.openai.azure.com")
        let url = try XCTUnwrap(FoundryProbeFetcher.probeURL(for: deployment))
        XCTAssertTrue(url.absoluteString.contains("/openai/models?api-version="))
    }

    func test_lookupAPIKey_normalizesProviderName() {
        let deployment = self.makeDeployment(providerKey: "pmi-foundry-project")
        let env = ["CODEXBAR_FOUNDRY_KEY_PMI_FOUNDRY_PROJECT": "abc"]
        XCTAssertEqual(FoundryProbeFetcher.lookupAPIKey(for: deployment, environment: env), "abc")
    }

    func test_probe_returnsMissingKeyWithoutNetwork() async {
        FoundryProbeStubURLProtocol.handler = { _ in
            XCTFail("Should not make a network call when API key is missing")
            return (HTTPURLResponse(), Data())
        }
        let result = await FoundryProbeFetcher.probe(
            deployment: self.makeDeployment(),
            environment: [:],
            session: self.makeSession())
        XCTAssertEqual(result.status, .missingKey)
        XCTAssertNil(result.httpStatus)
    }

    func test_probe_parsesRateLimitHeadersOn200() async throws {
        FoundryProbeStubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let http = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "x-ratelimit-limit-requests": "60",
                    "x-ratelimit-remaining-requests": "59",
                    "x-ratelimit-limit-tokens": "150000",
                    "x-ratelimit-remaining-tokens": "149200",
                    "x-ratelimit-reset-requests": "30",
                ])!
            return (http, Data())
        }
        let env = ["CODEXBAR_FOUNDRY_KEY_ANTHROPIC_FOUNDRY": "test-key"]
        let result = await FoundryProbeFetcher.probe(
            deployment: self.makeDeployment(),
            environment: env,
            session: self.makeSession())
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertEqual(result.limitRequests, "60")
        XCTAssertEqual(result.remainingTokens, "149200")
        XCTAssertNotNil(result.resetAt)
    }

    func test_probe_mapsStatusCodes() async throws {
        let cases: [(Int, FoundryDeploymentProbeResult.Status)] = [
            (401, .unauthorized),
            (403, .unauthorized),
            (404, .notFound),
            (429, .throttled),
            (500, .serverError),
            (503, .serverError),
        ]
        for (code, expected) in cases {
            FoundryProbeStubURLProtocol.handler = { request in
                let url = try XCTUnwrap(request.url)
                let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (http, Data())
            }
            let result = await FoundryProbeFetcher.probe(
                deployment: self.makeDeployment(),
                environment: ["CODEXBAR_FOUNDRY_KEY_ANTHROPIC_FOUNDRY": "k"],
                session: self.makeSession())
            XCTAssertEqual(result.status, expected, "status \(code)")
            XCTAssertEqual(result.httpStatus, code)
        }
    }

    func test_probe_handlesNetworkErrors() async {
        FoundryProbeStubURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let result = await FoundryProbeFetcher.probe(
            deployment: self.makeDeployment(),
            environment: ["CODEXBAR_FOUNDRY_KEY_ANTHROPIC_FOUNDRY": "k"],
            session: self.makeSession())
        XCTAssertEqual(result.status, .network)
        XCTAssertNil(result.httpStatus)
    }

    func test_probe_sendsBothAuthHeaders() async throws {
        FoundryProbeStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "secret-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-123")
            let url = try XCTUnwrap(request.url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        _ = await FoundryProbeFetcher.probe(
            deployment: self.makeDeployment(),
            environment: ["CODEXBAR_FOUNDRY_KEY_ANTHROPIC_FOUNDRY": "secret-123"],
            session: self.makeSession())
    }
}

// MARK: - URLProtocol stub

final class FoundryProbeStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.requests.append(self.request)
        Self.lock.unlock()
        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
