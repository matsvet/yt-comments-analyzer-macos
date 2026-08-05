import Foundation

/// Ошибки загрузки с понятными для пользователя сообщениями.
enum YouTubeError: LocalizedError, Equatable {
    case invalidURL
    case missingAPIKey
    case commentsDisabled
    case quotaExceeded
    case invalidAPIKey
    case videoNotFound
    case http(status: Int, reason: String?, message: String?)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Не удалось распознать ссылку на видео. Вставьте корректный URL YouTube или ID видео."
        case .missingAPIKey:
            return "Не указан API-ключ. Откройте настройки и введите ключ YouTube Data API."
        case .commentsDisabled:
            return "У этого видео отключены комментарии."
        case .quotaExceeded:
            return "Превышена дневная квота YouTube API. Попробуйте позже или используйте другой ключ."
        case .invalidAPIKey:
            return "API-ключ недействителен или не имеет доступа к YouTube Data API v3."
        case .videoNotFound:
            return "Видео не найдено."
        case let .http(status, reason, message):
            let extra = [reason, message].compactMap { $0 }.joined(separator: ": ")
            return extra.isEmpty ? "Ошибка YouTube API (HTTP \(status))." : "Ошибка YouTube API (HTTP \(status)): \(extra)"
        case let .network(text):
            return "Сетевая ошибка: \(text)"
        case let .decoding(text):
            return "Не удалось разобрать ответ API: \(text)"
        }
    }

    /// Маппинг машинной причины из тела ошибки YouTube в типизированную ошибку.
    static func from(status: Int, reason: String?, message: String?) -> YouTubeError {
        switch reason {
        case "commentsDisabled":
            return .commentsDisabled
        case "quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded", "userRateLimitExceeded":
            return .quotaExceeded
        case "keyInvalid", "badRequest", "forbidden":
            return .invalidAPIKey
        case "videoNotFound", "commentThreadNotFound", "parameterValueOutOfRange", "notFound":
            return .videoNotFound
        default:
            return .http(status: status, reason: reason, message: message)
        }
    }
}
