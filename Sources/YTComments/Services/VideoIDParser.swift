import Foundation

/// Извлекает 11-символьный videoId из разных форм ссылок YouTube либо из голого ID.
enum VideoIDParser {
    /// Разрешённый набор символов и длина id YouTube.
    private static let idPattern = "^[A-Za-z0-9_-]{11}$"

    static func extract(from rawInput: String) -> String? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // Голый ID.
        if isValidID(input) {
            return input
        }

        // Добавляем схему, иначе URL может не разобрать host.
        let normalized = input.contains("://") ? input : "https://\(input)"
        guard let url = URL(string: normalized),
              let host = url.host?.lowercased() else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host.contains("youtu.be") {
            return validated(pathComponents.first)
        }

        if host.contains("youtube.com") {
            // .../watch?v=ID
            if let queryV = queryItem(named: "v", in: url), let id = validated(queryV) {
                return id
            }
            // /shorts/ID, /embed/ID, /live/ID, /v/ID
            let prefixes: Set<String> = ["shorts", "embed", "live", "v"]
            if let first = pathComponents.first, prefixes.contains(first.lowercased()) {
                return validated(pathComponents.dropFirst().first)
            }
        }

        return nil
    }

    private static func isValidID(_ candidate: String) -> Bool {
        candidate.range(of: idPattern, options: .regularExpression) != nil
    }

    private static func validated(_ candidate: String?) -> String? {
        guard let candidate, isValidID(candidate) else { return nil }
        return candidate
    }

    private static func queryItem(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
