import Foundation
import Testing
@testable import YTComments

@Suite("LLM models", .serialized)
struct LLMClientTests {
    @Test func modelsAndErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(URL(string: "https://example.com/openai/v1/chat/completions"))
        let client = LLMClient(session: session, chatEndpoint: endpoint, apiKey: "test-secret")
        ModelProtocol.handler = { request in
            #expect(request.url?.path == "/openai/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            return (200, #"{"data":[{"id":"openai/gpt-oss-120b"}]}"#)
        }
        #expect(try await client.listModels() == ["openai/gpt-oss-120b"])

        for status in [401, 403, 429, 503] {
            ModelProtocol.handler = { _ in (status, "test-secret: provider error") }
            do {
                _ = try await client.listModels()
                Issue.record("HTTP error was swallowed")
            } catch let LLMError.http(actual, body) {
                #expect(actual == status)
                #expect(!body.contains("test-secret"))
                #expect(LLMError.http(status: actual, body: body).localizedDescription.contains("\(status)"))
            }
        }

        ModelProtocol.handler = { _ in (200, "invalid JSON") }
        await #expect(throws: DecodingError.self) { try await client.listModels() }

        ModelProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await client.listModels() }

        let localEndpoint = try #require(URL(string: "http://localhost:11434/v1/chat/completions"))
        let local = LLMClient(session: session, chatEndpoint: localEndpoint, apiKey: "")
        ModelProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.url?.path == "/v1/models" { return (404, "not found") }
            #expect(request.url?.path == "/api/tags")
            return (200, #"{"models":[{"name":"llama3.1:8b"}]}"#)
        }
        #expect(try await local.listModels() == ["llama3.1:8b"])
    }
}

private final class ModelProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (status, body) = try handler(request)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
