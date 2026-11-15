import Foundation
import Security
import Testing
@testable import YTComments

@Suite("ChatGPT subscription")
struct ChatGPTTests {
    @MainActor @Test func callbackAndFormEncoding() throws {
        let url = try #require(URL(string: "http://127.0.0.1:54321/auth/callback?state=expected&code=code&client_id=oaiapp_test"))
        let (code, client) = try ChatGPTSession.validateCallback(url, state: "expected", savedClientID: nil)
        #expect(code == "code" && client == "oaiapp_test")
        for invalid in [
            "http://127.0.0.1/auth/callback?state=wrong&code=x&client_id=oaiapp_test",
            "http://127.0.0.1/auth/callback?state=expected&state=expected&code=x&client_id=oaiapp_test",
            "http://127.0.0.1/auth/callback?state=expected&code=x&client_id=dynamic_agent_client",
            "http://127.0.0.1/auth/callback?state=expected&code=x&client_id=oaiapp_other",
            "http://127.0.0.1/auth/callback?state=expected&error=access_denied",
            "https://evil.example/auth/callback?state=expected&code=x&client_id=oaiapp_test"
        ] {
            #expect(throws: (any Error).self) {
                try ChatGPTSession.validateCallback(URL(string: invalid)!, state: "expected", savedClientID: "oaiapp_test")
            }
        }
        let returning = URL(string: "http://127.0.0.1/auth/callback?state=expected&code=next")!
        #expect(try ChatGPTSession.validateCallback(returning, state: "expected", savedClientID: "oaiapp_test").1 == "oaiapp_test")
        let request = ChatGPTSession.formRequest(url: url, fields: ["token": "a+b&c=d /?"])
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == "token=a%2Bb%26c%3Dd%20%2F%3F")
    }

    @MainActor @Test func loopbackCallbackAndCancellation() async throws {
        let callback = try OAuthCallback(state: "expected")
        defer { callback.cancel() }
        let redirect = try await callback.start()
        let task = Task { try await callback.result() }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // Invalid requests must not consume the callback or exhaust connection slots.
        for _ in 0..<9 {
            _ = try? await session.data(from: URL(string: redirect + "?state=wrong&code=forged")!)
        }
        let url = try #require(URL(string: redirect + "?state=expected&code=real&client_id=oaiapp_test"))
        let (body, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!body.isEmpty)
        #expect(try await task.value == url)
        let cancelled = try OAuthCallback(state: "cancelled")
        _ = try await cancelled.start()
        let pending = Task { try await cancelled.result() }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        cancelled.cancel()
    }

    @MainActor @Test func signedIdentityValidation() throws {
        let privateKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Extract the two integers from the generated PKCS#1 public key for the mock JWKS.
        let bytes = Array(der)
        var offset = 1
        func length() -> Int {
            let first = Int(bytes[offset]); offset += 1
            if first < 128 { return first }
            var value = 0
            for _ in 0..<(first & 127) { value = value * 256 + Int(bytes[offset]); offset += 1 }
            return value
        }
        _ = length()
        func integer() -> Data {
            offset += 1
            let count = length()
            let value = Data(bytes[offset..<(offset + count)])
            offset += count
            return value.first == 0 ? Data(value.dropFirst()) : value
        }
        let n = integer(), e = integer()
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "n": n.base64URL, "e": e.base64URL]]])
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": ["oaiapp_test"], "sub": "user", "email": "test@example.com", "iat": now, "exp": now + 300, "nonce": "nonce"]
        func signed(_ claims: [String: Any]) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]).base64URL
            let body = try JSONSerialization.data(withJSONObject: claims).base64URL
            let input = header + "." + body
            let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
            return input + "." + signature.base64URL
        }
        let valid = try signed(claims)
        #expect(try ChatGPTSession.verifyIdentity(valid, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce").subject == "user")
        #expect(throws: (any Error).self) { try ChatGPTSession.verifyIdentity(valid, jwks: jwks, clientID: "other", nonce: "nonce") }
        #expect(throws: (any Error).self) { try ChatGPTSession.verifyIdentity(valid, jwks: jwks, clientID: "oaiapp_test", nonce: "wrong") }
        for (key, value) in [("exp", now - 30 as Any), ("iss", "https://evil.example" as Any), ("iat", now + 300 as Any)] {
            var bad = claims; bad[key] = value
            let token = try signed(bad)
            #expect(throws: (any Error).self) { try ChatGPTSession.verifyIdentity(token, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce") }
        }
        claims["sub"] = "attacker"
        let forgedBody = try JSONSerialization.data(withJSONObject: claims).base64URL
        let parts = valid.components(separatedBy: ".")
        let forged = parts[0] + "." + forgedBody + "." + parts[2]
        #expect(throws: (any Error).self) { try ChatGPTSession.verifyIdentity(forged, jwks: jwks, clientID: "oaiapp_test", nonce: "nonce") }
    }

    @Test func requestsAndStreamFailures() throws {
        let data = try ChatGPTClient.requestBody(messages: [.init(role: .system, content: "rules"), .init(role: .user, content: "question")], model: "chosen-model", jsonResponse: true)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "chosen-model")
        #expect((body["reasoning"] as? [String: String]) == ["effort": "medium"])
        for effort in ReasoningEffort.allCases {
            let data = try ChatGPTClient.requestBody(messages: [.init(role: .user, content: "question")], model: "chosen-model", jsonResponse: false, reasoningEffort: effort)
            let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((request["reasoning"] as? [String: String]) == ["effort": effort.rawValue])
        }
        #expect((body["input"] as? [[String: String]]) == [["role": "user", "content": "question"]])
        #expect(body["tools"] == nil && body["temperature"] == nil && body["max_output_tokens"] == nil)
        var stream = ChatGPTClient.ResponseStream()
        #expect(try stream.consume(": keepalive") == nil)
        #expect(try stream.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}") == nil)
        #expect(try stream.consume("") == nil)
        #expect(try stream.consume(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"final"}]}]}}"#) == nil)
        #expect(try stream.consume("") == "final")
        for payload in [
            #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#,
            #"{"type":"response.incomplete"}"#,
            #"{"type":"response.completed","response":{"status":"incomplete"}}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#,
            #"{"type":"response.refusal.delta","delta":"no"}"#,
            "[DONE]", "invalid JSON"
        ] {
            var parser = ChatGPTClient.ResponseStream()
            _ = try parser.consume("data: " + payload)
            #expect(throws: (any Error).self) { try parser.consume("") }
        }
    }
}
