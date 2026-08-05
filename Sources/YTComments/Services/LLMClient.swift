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
        let requestBody = OpenAIChatRequest(
            model: model,
            messages: [
                OpenAIMessage(role: "system", content: system),
                OpenAIMessage(role: "user", content: user)
            ],
            stream: false
        )

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

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(status: httpResponse.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }

    /// Пытается получить список моделей (для статуса).
    /// Для локальной Ollama использует /api/tags как fallback.
    func listModels() async -> [String]? {
        // Сначала попробуем OpenAI-совместимый /v1/models
        if let modelsURL = makeModelsURL(from: chatEndpoint) {
            var request = URLRequest(url: modelsURL)
            request.httpMethod = "GET"
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, resp) = try await session.data(for: request)
                if (resp as? HTTPURLResponse)?.statusCode == 200,
                   let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) {
                    return decoded.data.map { $0.id }
                }
            } catch { }
        }

        // Fallback для классической локальной Ollama
        if chatEndpoint.absoluteString.contains("localhost:11434") || chatEndpoint.absoluteString.contains("127.0.0.1:11434") {
            if let tagsURL = URL(string: "http://localhost:11434/api/tags") {
                do {
                    let (data, resp) = try await session.data(from: tagsURL)
                    if (resp as? HTTPURLResponse)?.statusCode == 200,
                       let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) {
                        return tags.models.map { $0.name }
                    }
                } catch { }
            }
        }
        return nil
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
        let messages: [OpenAIMessage]
        let stream: Bool
    }

    private struct OpenAIMessage: Codable {
        let role: String
        let content: String
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

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Неверный адрес LLM endpoint."
        case .http(let status, let body):
            return "Ошибка LLM (HTTP \(status)): \(body.prefix(200))"
        case .emptyResponse:
            return "Пустой ответ от модели."
        case .network(let text):
            return "Сетевая ошибка: \(text)"
        }
    }
}