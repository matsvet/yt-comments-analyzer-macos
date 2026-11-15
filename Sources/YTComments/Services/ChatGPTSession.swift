import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// One local ChatGPT registration. Tokens never leave Keychain or OpenAI requests.
@Observable @MainActor
final class ChatGPTSession {
    private(set) var cacheIdentity = UUID()
    private(set) var email: String?
    private(set) var isSigningIn = false
    private(set) var isSigningOut = false
    private(set) var message = "Войдите в ChatGPT и разрешите использование подписки."
    var isConnected: Bool { credential?.accessToken != nil }
    @ObservationIgnored private var credential: Credential?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<String, Error>?
    @ObservationIgnored private var generation = UUID()
    private static let service = "YTCommentsAnalyzer.ChatGPT"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    struct Credential: Codable {
        let clientID: String
        let subject: String
        let email: String?
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date
        var scopes: [String]
    }

    init() {
        do {
            if let data = try Self.readKeychain() {
                credential = try JSONDecoder().decode(Credential.self, from: data)
                email = credential?.email
                message = isConnected ? "ChatGPT подключён. Запросы используют лимиты подписки." : "Войдите снова в сохранённый аккаунт ChatGPT."
            }
        } catch { message = error.localizedDescription }
    }

    func signIn() {
        guard !isSigningIn, !isSigningOut, refreshTask == nil else { return }
        isSigningIn = true
        message = "Завершите вход и разрешите использование подписки в браузере."
        loginTask = Task {
            do {
                let old = credential
                generation = UUID()
                let state = try Self.randomValue()
                let nonce = try Self.randomValue()
                let verifier = try Self.randomValue()
                let callback = try OAuthCallback(state: state)
                defer { callback.cancel() }
                let redirect = try await callback.start()
                var host = UserDefaults.standard.string(forKey: "ChatGPTHostID")
                if host == nil {
                    host = "urn:uuid:" + UUID().uuidString.lowercased()
                    UserDefaults.standard.set(host, forKey: "ChatGPTHostID")
                }
                var parameters = [
                    "client_id": old?.clientID ?? "dynamic_agent_client",
                    "ext_agent_host_id": host!, "response_type": "code", "redirect_uri": redirect,
                    "scope": Self.scope, "resource": "https://api.openai.com/v1", "state": state,
                    "nonce": nonce, "code_challenge_method": "S256",
                    "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
                ]
                if old == nil { parameters["agent_name_hint"] = "YT Comments Analyzer" }
                if let hint = old?.idToken { parameters["id_token_hint"] = hint }
                if let email = old?.email { parameters["login_hint"] = email }
                if old != nil && !(old?.scopes.contains("chatgpt.tokens.use.direct") ?? false) {
                    parameters["prompt"] = "consent"
                }
                var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
                url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
                guard NSWorkspace.shared.open(url.url!) else { throw failure("Не удалось открыть браузер.") }
                let result = try await callback.result()
                let (code, clientID) = try Self.validateCallback(result, state: state, savedClientID: old?.clientID)
                let tokens = try await Self.exchange([
                    "grant_type": "authorization_code", "client_id": clientID, "code": code,
                    "code_verifier": verifier, "redirect_uri": redirect, "resource": "https://api.openai.com/v1"
                ])
                guard let idToken = tokens.id_token else { throw failure("OpenAI не вернул ID token.") }
                let identity = try await Self.verifyIdentity(idToken, clientID: clientID, nonce: nonce)
                guard old == nil || old?.subject == identity.subject else {
                    throw failure("Аккаунт не совпадает с сохранённой регистрацией ChatGPT.")
                }
                try Task.checkCancellation()
                let scopes = tokens.scope?.split(separator: " ").map(String.init) ?? []
                let value = Credential(clientID: clientID, subject: identity.subject, email: identity.email,
                                       accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
                                       idToken: idToken, expiresAt: Date().addingTimeInterval(tokens.expires_in), scopes: scopes)
                try save(value)
                cacheIdentity = UUID()
                message = scopes.contains("chatgpt.tokens.use.direct")
                    ? "ChatGPT подключён. Запросы используют лимиты подписки."
                    : "Вход выполнен, но доступ к подписке не разрешён. Нажмите «Продолжить с ChatGPT» ещё раз."
            } catch is CancellationError { message = "Вход отменён." }
            catch { message = error.localizedDescription }
            isSigningIn = false
            loginTask = nil
        }
    }

    func cancelSignIn() { loginTask?.cancel() }

    func signOut() async {
        guard !isSigningIn, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        if let refreshTask { _ = try? await refreshTask.value }
        guard var value = credential else { return }
        generation = UUID()
        cacheIdentity = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        var revoked = value.refreshToken == nil
        if let token = value.refreshToken {
            do {
                let discovery = try await Self.discovery()
                guard let endpoint = discovery["revocation_endpoint"], Self.isAuthURL(endpoint) else { throw failure("Неверный адрес отзыва сессии.") }
                let (_, response) = try await URLSession.shared.data(for: Self.formRequest(url: URL(string: endpoint)!, fields: [
                    "token": token, "token_type_hint": "refresh_token", "client_id": value.clientID
                ]))
                revoked = (response as? HTTPURLResponse)?.statusCode == 200
            } catch { revoked = false }
        }
        value.accessToken = nil; value.refreshToken = nil; value.idToken = nil
        do {
            try save(value)
            message = revoked ? "Вы вышли из ChatGPT." : "Вы вышли локально. Отзыв сессии не подтверждён; отключите приложение в настройках ChatGPT."
        } catch { message = error.localizedDescription }
    }

    func accessToken() async throws -> String {
        guard !isSigningOut, !isSigningIn else { throw failure("Дождитесь завершения входа или выхода ChatGPT.") }
        guard let value = credential, let token = value.accessToken else { throw failure("Войдите в ChatGPT в настройках приложения.") }
        guard value.scopes.contains("chatgpt.tokens.use.direct") else { throw failure("Разрешите использование подписки через «Продолжить с ChatGPT» в настройках.") }
        if value.expiresAt.timeIntervalSinceNow > 60 { return token }
        if let refreshTask { return try await refreshTask.value }
        let currentGeneration = generation
        let task = Task<String, Error> {
            guard let refreshToken = value.refreshToken else { throw failure("Сессия ChatGPT истекла. Войдите снова.") }
            do {
                let tokens = try await Self.exchange(["grant_type": "refresh_token", "client_id": value.clientID,
                                                     "refresh_token": refreshToken, "resource": "https://api.openai.com/v1"])
                try Task.checkCancellation()
                guard generation == currentGeneration else { throw CancellationError() }
                var renewed = value
                renewed.accessToken = tokens.access_token
                renewed.refreshToken = tokens.refresh_token ?? value.refreshToken
                renewed.idToken = tokens.id_token ?? value.idToken
                renewed.expiresAt = Date().addingTimeInterval(tokens.expires_in)
                if let scope = tokens.scope { renewed.scopes = scope.split(separator: " ").map(String.init) }
                try save(renewed)
                guard renewed.scopes.contains("chatgpt.tokens.use.direct") else { throw failure("ChatGPT больше не разрешает использование подписки. Войдите снова.") }
                return tokens.access_token
            } catch let error as OAuthFailure {
                if ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(error.code), generation == currentGeneration {
                    var cleared = value
                    cleared.accessToken = nil; cleared.refreshToken = nil; cleared.idToken = nil
                    try save(cleared)
                }
                throw error
            }
        }
        refreshTask = task
        defer { if generation == currentGeneration { refreshTask = nil } }
        return try await task.value
    }

    private func save(_ value: Credential) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service, kSecAttrAccount as String: "session"]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure("Не удалось сохранить сессию ChatGPT в Keychain.") }
        } else if status != errSecSuccess { throw failure("Не удалось обновить сессию ChatGPT в Keychain.") }
        credential = value
        email = value.email
    }

    private static func readKeychain() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: service, kSecAttrAccount as String: "session",
                                         kSecReturnData as String: true] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure("Не удалось прочитать сессию ChatGPT из Keychain.") }
        return result as? Data
    }

    struct OAuthFailure: LocalizedError {
        let code: String
        var errorDescription: String? { "Авторизация ChatGPT: \(code). Повторите вход; при сетевой ошибке попробуйте позже." }
    }
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double
        let scope: String?
    }

    private static func exchange(_ fields: [String: String]) async throws -> Tokens {
        let (data, response) = try await URLSession.shared.data(for: formRequest(url: tokenURL, fields: fields))
        guard let http = response as? HTTPURLResponse else { throw failure("OpenAI не вернул HTTP-ответ.") }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = body?["error"] as? String ?? "HTTP \(http.statusCode)"
            throw OAuthFailure(code: code)
        }
        let result = try JSONDecoder().decode(Tokens.self, from: data)
        guard !result.access_token.isEmpty, result.expires_in.isFinite, result.expires_in > 0 else { throw failure("OpenAI вернул неверную сессию.") }
        return result
    }

    static func formRequest(url: URL, fields: [String: String]) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    static func validateCallback(_ url: URL, state: String, savedClientID: String?) throws -> (String, String) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.host == "127.0.0.1",
              parts.scheme == "http", parts.path == "/auth/callback" else { throw failure("Неверный адрес возврата ChatGPT.") }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else { throw failure("Не удалось проверить вход ChatGPT (state).") }
        func value(_ key: String) -> String? { items.first(where: { $0.name == key })?.value }
        if value("error") != nil { throw failure("Вход ChatGPT отклонён. Повторите вход и разрешите использование подписки.") }
        guard let code = value("code"), !code.isEmpty,
              let client = value("client_id") ?? savedClientID, client.hasPrefix("oaiapp_"),
              savedClientID == nil || client == savedClientID else { throw failure("Неверная регистрация ChatGPT.") }
        return (code, client)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Не удалось создать параметры безопасного входа.") }
        return Data(bytes).base64URL
    }

    private static func isAuthURL(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "https" && url.host == "auth.openai.com" && url.user == nil && url.password == nil
    }

    private static func discovery() async throws -> [String: String] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["issuer"] as? String == "https://auth.openai.com" else { throw failure("Не удалось проверить сервер авторизации OpenAI.") }
        return body.compactMapValues { $0 as? String }
    }

    private static func verifyIdentity(_ token: String, clientID: String, nonce: String) async throws -> (subject: String, email: String?) {
        let config = try await discovery()
        guard let uri = config["jwks_uri"], isAuthURL(uri) else { throw failure("Неверный адрес ключей OpenAI.") }
        let (data, response) = try await URLSession.shared.data(from: URL(string: uri)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("Не удалось загрузить ключи OpenAI.") }
        return try verifyIdentity(token, jwks: data, clientID: clientID, nonce: nonce)
    }

    static func verifyIdentity(_ token: String, jwks: Data, clientID: String, nonce: String) throws -> (subject: String, email: String?) {
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3, let header = Data(base64URL: parts[0]), let claims = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let h = try JSONSerialization.jsonObject(with: header) as? [String: Any], h["alg"] as? String == "RS256",
              let kid = h["kid"] as? String,
              let keys = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let key = (keys["keys"] as? [[String: Any]])?.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) else { throw failure("Неверная подпись ID token ChatGPT.") }
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            let length = bytes.count
            let encodedLength: [UInt8] = length < 128 ? [UInt8(length)] : (length < 256 ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 255)])
            return Data([tag] + encodedLength) + bytes
        }
        func integer(_ bytes: Data) -> Data { der(0x02, (bytes.first.map { $0 >= 128 } == true ? Data([0]) : Data()) + bytes) }
        let rsa = der(0x30, integer(modulus) + integer(exponent))
        guard let publicKey = SecKeyCreateWithData(rsa as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let c = try JSONSerialization.jsonObject(with: claims) as? [String: Any],
              c["iss"] as? String == "https://auth.openai.com", c["nonce"] as? String == nonce,
              (c["aud"] as? String == clientID || (c["aud"] as? [String])?.contains(clientID) == true),
              let expires = c["exp"] as? Double, expires > Date().timeIntervalSince1970 - 5,
              let issued = c["iat"] as? Double, issued <= Date().timeIntervalSince1970 + 5,
              let subject = c["sub"] as? String, !subject.isEmpty else { throw failure("Не удалось проверить личность ChatGPT.") }
        return (subject, c["email"] as? String)
    }
}

func failure(_ message: String) -> LLMError { .network(message) }

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
}

/// Loopback only, ephemeral port, bounded request size and lifetime, one callback.
@MainActor
final class OAuthCallback {
    private let listener: NWListener
    private let state: String
    private var completion: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var connections: [NWConnection] = []
    private var timeout: Task<Void, Never>?

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<String, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self, !resumed else { return }
                    switch status {
                    case .ready:
                        resumed = true
                        ready.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)/auth/callback")
                    case .failed(let error): resumed = true; ready.resume(throwing: error)
                    case .cancelled: resumed = true; ready.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.connections.count < 8 else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, buffer: Data())
                }
            }
            listener.start(queue: .main)
        }
    }

    func result() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let outcome { return try outcome.get() }
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                timeout = Task {
                    try? await Task.sleep(for: .seconds(180))
                    if !Task.isCancelled { finish(.failure(failure("Время входа ChatGPT истекло. Повторите вход."))) }
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let buffer = buffer + (data ?? Data())
                guard buffer.count <= 16384, error == nil else { self.close(connection); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if done { self.close(connection) } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let line = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                let base = "http://127.0.0.1:\(self.listener.port?.rawValue ?? 0)"
                guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/auth/callback?"),
                      let url = URL(string: base + line[1]),
                      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      parts.queryItems?.first(where: { $0.name == "state" })?.value == self.state else { self.close(connection); return }
                let body = "Возвращайтесь в YT Comments Analyzer для завершения входа."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in
                        self?.close(connection)
                        self?.finish(.success(url))
                    }
                })
            }
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    private func finish(_ value: Result<URL, Error>) {
        guard outcome == nil else { return }
        outcome = value
        completion?.resume(with: value)
        completion = nil
        timeout?.cancel()
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections = []
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}
