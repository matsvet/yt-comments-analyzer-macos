import Foundation

/// Subscription route: Responses API only, no tools, full context per request.
struct ChatGPTClient {
    var session: URLSession = .shared
    let account: ChatGPTSession
    var reasoningEffort: ReasoningEffort = .medium

    func listModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 30)
        let token = try await account.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data, token: token)
        struct Catalog: Decodable {
            let models: [Model]
            struct Model: Decodable { let slug: String; let visibility: String }
        }
        return try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }.map(\.slug)
    }

    func chat(messages: [LLMClient.Message], model: String, jsonResponse: Bool) async throws -> String {
        guard !model.isEmpty else { throw failure("Загрузите и выберите модель ChatGPT в настройках приложения.") }
        let token = try await account.accessToken()
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.requestBody(messages: messages, model: model, jsonResponse: jsonResponse, reasoningEffort: reasoningEffort)
        let (bytes, response) = try await session.bytes(for: request)
        if (response as? HTTPURLResponse).map({ !(200..<300).contains($0.statusCode) }) ?? true {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 16384 { break }
            }
            try Self.check(response, body: body, token: token)
        }
        var parser = ResponseStream()
        // Preserve blank SSE lines: Foundation's lines sequence may omit them.
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                guard let decoded = String(data: line, encoding: .utf8) else { throw failure("Неверная кодировка ответа ChatGPT.") }
                if let answer = try parser.consume(decoded) { return answer }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                guard line.count <= 2_000_000 else { throw failure("Слишком большой фрагмент ответа ChatGPT.") }
            }
        }
        throw failure("ChatGPT прервал ответ до завершения. Повторите запрос.")
    }

    static func requestBody(messages: [LLMClient.Message], model: String, jsonResponse: Bool, reasoningEffort: ReasoningEffort = .medium) throws -> Data {
        var instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        if jsonResponse { instructions += "\nВерни только валидный JSON без Markdown и блоков кода." }
        // ponytail: existing JSON instructions + validation cover chat; no separate schema system.
        let input = messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] }
        return try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instructions,
                                                          "input": input, "store": false, "stream": true,
                                                          "reasoning": ["effort": reasoningEffort.rawValue]])
    }

    private static func check(_ response: URLResponse, body: Data, token: String) throws {
        guard let http = response as? HTTPURLResponse else { throw failure("ChatGPT не вернул HTTP-ответ.") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = error?["code"] as? String
            let detail = code ?? (object?["detail"] as? String) ?? "Ошибка запроса"
            let id = http.value(forHTTPHeaderField: "x-request-id") ?? ""
            throw failure("ChatGPT (HTTP \(http.statusCode)): \(detail.replacingOccurrences(of: token, with: "[скрыто]").prefix(300))\(id.isEmpty ? "" : "; запрос: " + id). \(guidance(code, status: http.statusCode))")
        }
    }

    static func guidance(_ code: String?, status: Int = 0) -> String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return "Достигнут лимит подписки или приложения. Проверьте ChatGPT → Настройки → Использование."
        case "subscription_sharing_user_not_eligible": return "Использование подписки недоступно для этого аккаунта или рабочего пространства."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return "Сервис временно недоступен. Повторите позже."
        case "subscription_sharing_unsupported_capability": return "Выберите другую модель или уровень размышления; запрошенная возможность не поддерживается."
        default: return status == 401 ? "Войдите в ChatGPT снова в настройках." : "Проверьте доступ аккаунта и попробуйте позже."
        }
    }

    /// SSE data can span multiple lines. A partial answer is never treated as success.
    struct ResponseStream {
        private var data: [String] = []
        private var text = ""

        mutating func consume(_ line: String) throws -> String? {
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.first == " " { value.removeFirst() }
                data.append(value)
                return nil
            }
            guard line.isEmpty, !data.isEmpty else { return nil }
            let payload = data.joined(separator: "\n")
            data = []
            guard payload != "[DONE]" else { throw failure("ChatGPT завершил поток без подтверждения ответа.") }
            guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = event["type"] as? String else { throw failure("Неверный формат потока ChatGPT.") }
            switch type {
            case "response.output_text.delta": text += event["delta"] as? String ?? ""
            case "response.refusal.delta": throw failure("ChatGPT отказался отвечать на этот запрос.")
            case "response.completed":
                let response = event["response"] as? [String: Any]
                guard response?["status"] as? String == "completed" else { throw failure("ChatGPT не завершил ответ.") }
                // The completed response is authoritative, including when deltas were absent.
                if let output = response?["output"] as? [[String: Any]] {
                    let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    if content.contains(where: { $0["type"] as? String == "refusal" }) { throw failure("ChatGPT отказался отвечать на этот запрос.") }
                    let final = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
                    if !final.isEmpty { text = final }
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
                return text
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any]) ?? event
                let code = error["code"] as? String
                throw failure("ChatGPT: \(code ?? type). \(ChatGPTClient.guidance(code))")
            default: break
            }
            return nil
        }
    }
}

/// Explicit choice shared by summaries and comment chat. Default preserves GPT-6.1 Sol behavior.
enum ReasoningEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "Низкий · low"
        case .medium: return "Средний · medium"
        case .high: return "Высокий · high"
        case .xhigh: return "Очень высокий · xhigh"
        case .max: return "Максимальный · max"
        }
    }
    var detail: String {
        switch self {
        case .low: return "Быстрее и экономнее. Подходит для коротких саммари и простых вопросов."
        case .medium: return "Баланс скорости и глубины. Уровень по умолчанию для GPT-6.1 Sol."
        case .high, .xhigh, .max: return "Больше времени на анализ сложных вопросов; расход лимитов может вырасти."
        }
    }
}
