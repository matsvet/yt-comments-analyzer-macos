import Foundation

/// Ограниченная подборка из локальных комментариев. Поиск не обращается в сеть.
struct CommentChatContext {
    let comments: [StoredComment]
    let text: String

    init(video: VideoComments, question: String, previousQuestion: String = "", previousSources: [StoredComment] = []) {
        let terms = Self.terms(in: question)
        let previousTerms = Self.terms(in: previousQuestion)
        let priorIDs = Set(previousSources.map(\.id))
        let ranked = video.comments.enumerated().map { index, comment in
            let text = (comment.author + " " + comment.text).lowercased()
            let hits = terms.filter { text.contains($0) }.count
            let historyHits = previousTerms.filter { text.contains($0) }.count
            let score = hits * 20 + (terms.count < 4 ? historyHits * 3 : 0)
                + (priorIDs.contains(comment.id) ? 2 : 0)
            return (comment: comment, score: score, index: index)
        }.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.comment.likeCount != right.comment.likeCount { return left.comment.likeCount > right.comment.likeCount }
            return left.index < right.index
        }.map(\.comment)

        let roots = Dictionary(video.comments.filter(\.isTopLevel).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replies = Dictionary(grouping: video.comments.filter { !$0.isTopLevel }, by: \.threadId)
        var selected: [StoredComment] = []
        var seen = Set<String>()
        var fragments: [String] = []
        var remaining = 6500

        func append(_ comment: StoredComment) {
            guard seen.insert(comment.id).inserted, remaining > 200 else { return }
            let number = selected.count + 1
            let header = "[\(number)] \(comment.author.prefix(100)); лайков: \(comment.likeCount); \(comment.isTopLevel ? "корень треда" : "ответ"):\n"
            let limit = min(1200, remaining - header.count - 60)
            guard limit > 0 else { return }
            let matches = terms.compactMap { comment.text.range(of: $0, options: .caseInsensitive) }
            let hit = matches.min { $0.lowerBound < $1.lowerBound }
            let start = hit.flatMap { comment.text.index($0.lowerBound, offsetBy: -120, limitedBy: comment.text.startIndex) }
                ?? comment.text.startIndex
            let tail = comment.text[start...]
            let excerpt = String(tail.prefix(limit))
            let fragment = header + (start != comment.text.startIndex ? "[начало опущено] " : "")
                + excerpt + (excerpt.count < tail.count ? " [фрагмент обрезан]" : "")
            selected.append(comment)
            fragments.append(fragment)
            remaining -= fragment.count + 2
        }

        for comment in ranked {
            // Совпадение получает место раньше соседних реплик; затем добавляем контекст и возражения.
            append(comment)
            if let root = roots[comment.threadId] { append(root) }
            for reply in (replies[comment.threadId] ?? []).prefix(2) { append(reply) }
            if remaining <= 200 { break }
        }
        comments = selected
        text = "Передано \(selected.count) из \(video.comments.count) комментариев. Это найденные фрагменты, не вся дискуссия.\n\n" + fragments.joined(separator: "\n\n")
    }

    private static func terms(in text: String) -> Set<String> {
        let stopWords: Set<String> = ["что", "это", "как", "для", "про", "или", "так", "все", "его", "она", "они", "мне", "меня", "тебя", "тут", "там", "есть", "нет", "кто", "чем", "этом", "этого", "какие", "какой", "почему", "расскажи", "подробнее", "комментарии", "комментариях", "саммари", "сказал", "можно", "только", "вообще", "было", "были", "the", "and", "what", "about"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
            .map { $0.count > 5 ? String($0.prefix(5)) : $0 })
    }
}
