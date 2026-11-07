import Foundation

/// Универсальный клиент для LLM (локальная Ollama или любые облачные OpenAI-совместимые API).
/// Поддерживает бесплатные облачные модели (Groq, OpenRouter free tier, Together.ai и т.д.).
/// Использует только стандартные библиотеки Foundation.
/// Формат: OpenAI /v1/chat/completions (Ollama тоже поддерживает его по адресу /v1/...).
struct LLMClient {
    var session: URLSession = .shared

    /// Полный URL к /chat/completions endpoint.
    /// Для локальной Ollama: "http://localhost:11434/v1/chat/completions"
    /// Для Groq: "https://api.groq.com/openai/v1/chat/completions"
    /// Для OpenRouter: "https://openrouter.ai/api/v1/chat/completions"
    var chatEndpoint: URL = URL(string: "http://localhost:11434/v1/chat/completions")!

    /// API ключ. Для локальной Ollama обычно "ollama" (игнорируется) или пусто.
    /// Для Groq / OpenRouter — ваш бесплатный ключ.
    var apiKey: String = "ollama"

    /// Выполняет chat completion с system и user сообщениями.
    /// Возвращает текст ответа.
    func chat(system: String, user: String, model: String) async throws -> String {
        try await chat(messages: [.init(role: .system, content: system), .init(role: .user, content: user)], model: model)
    }

    struct Message: Codable {
        enum Role: String, Codable { case system, user, assistant }
        let role: Role
        let content: String
    }

    func chat(messages: [Message], model: String, jsonResponse: Bool = false) async throws -> String {
        let requestBody = OpenAIChatRequest(model: model, messages: messages, stream: false,
                                            response_format: jsonResponse ? .init(type: "json_object") : nil)

        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.network("Нет HTTP ответа")
        }

        if httpResponse.statusCode == 429 {
            let delay = Double(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw LLMError.rateLimited(retryAfter: delay.isFinite ? max(1, delay) : 60)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var body = String(data: data, encoding: .utf8) ?? ""
            if !apiKey.isEmpty { body = body.replacingOccurrences(of: apiKey, with: "[скрыто]") }
            throw LLMError.http(status: httpResponse.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }

    /// Загружает модели, сохраняя причину ошибки для диагностики в настройках.
    func listModels() async throws -> [String] {
        guard let modelsURL = makeModelsURL(from: chatEndpoint) else {
            throw LLMError.invalidURL
        }
        do {
            let data = try await modelData(from: modelsURL)
            return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map { $0.id }
        } catch {
            // Только локальная Ollama поддерживает резервный /api/tags.
            guard ["localhost", "127.0.0.1"].contains(chatEndpoint.host ?? ""),
                  chatEndpoint.port == 11434 else { throw error }
            let tagsURL = chatEndpoint.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("api/tags")
            let data = try await modelData(from: tagsURL)
            return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models.map { $0.name }
        }
    }

    private func modelData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LLMError.network("Нет HTTP ответа")
        }
        guard (200...299).contains(response.statusCode) else {
            var body = String(data: data, encoding: .utf8) ?? ""
            if !apiKey.isEmpty { body = body.replacingOccurrences(of: apiKey, with: "[скрыто]") }
            throw LLMError.http(status: response.statusCode, body: body)
        }
        return data
    }

    private func makeModelsURL(from chatURL: URL) -> URL? {
        var urlString = chatURL.absoluteString
        if urlString.hasSuffix("/chat/completions") {
            urlString = String(urlString.dropLast("/chat/completions".count)) + "/models"
        } else if urlString.hasSuffix("/v1") || urlString.hasSuffix("/v1/") {
            urlString = urlString.trimmingCharacters(in: ["/"]) + "/models"
        } else {
            return nil
        }
        return URL(string: urlString)
    }

    // MARK: - Internal models for OpenAI format

    private struct OpenAIChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let response_format: ResponseFormat?
        struct ResponseFormat: Encodable { let type: String }
    }

    private struct OpenAIChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
            struct Message: Decodable {
                let content: String
            }
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        let data: [Model]
        struct Model: Decodable {
            let id: String
        }
    }

    private struct OllamaTagsResponse: Decodable {
        let models: [OllamaModel]
        struct OllamaModel: Decodable { let name: String }
    }
}

/// Ошибки при работе с LLM (локальной или облачной).
enum LLMError: LocalizedError {
    case invalidURL
    case http(status: Int, body: String)
    case emptyResponse
    case network(String)
    case rateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Неверный адрес LLM endpoint."
        case .http(let status, _) where status == 401:
            return "LLM: API-ключ недействителен или отозван (HTTP 401). Создайте новый ключ у провайдера."
        case .http(let status, _) where status == 403:
            return "LLM: доступ запрещён (HTTP 403). Проверьте ограничения провайдера, сети или VPN."
        case .http(let status, _) where status == 429:
            return "LLM: превышен лимит запросов или квота (HTTP 429). Повторите позже или проверьте лимиты аккаунта."
        case .http(let status, let body):
            return "Ошибка LLM (HTTP \(status)): \(body.prefix(200))"
        case .emptyResponse:
            return "Пустой ответ от модели."
        case .rateLimited(let delay):
            return "LLM: превышен лимит запросов (HTTP 429). Повторите через \(Int(min(delay, 86400).rounded(.up))) с."
        case .network(let text):
            return "Сетевая ошибка: \(text)"
        }
    }
}