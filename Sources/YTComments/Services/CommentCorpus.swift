import CryptoKit
import Foundation
import NaturalLanguage

/// Общий корпус: стабильные номера, локальный поиск, порции и проверяемые цитаты.
struct CommentCorpus {
    struct Fragment {
        let number: Int
        let text: String
    }
    struct Batch {
        let fragments: [Fragment]
        let text: String
        var numbers: Set<Int> { Set(fragments.map(\.number)) }
    }
    struct Evidence: Codable, Hashable {
        let source: Int
        let quote: String
    }
    struct Finding: Codable {
        let text: String
        let evidence: [Evidence]
    }
    let video: VideoComments
    let key: String
    let comments: [StoredComment]
    private let documents: [[String: Int]]
    private let frequencies: [String: Int]
    private let averageLength: Double
    private let roots: [String: StoredComment]

    init(video: VideoComments) {
        self.video = video
        comments = Self.sourceComments(in: video)
        // Ключ включает содержимое: повторная загрузка того же videoId не возвращает старый анализ.
        key = SHA256.hash(data: (try? JSONEncoder().encode(video)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        documents = comments.map { comment in
            Self.tokens(comment.author + " " + comment.text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        var df: [String: Int] = [:]
        for document in documents { for word in document.keys { df[word, default: 0] += 1 } }
        frequencies = df
        averageLength = max(1, Double(documents.reduce(0) { $0 + $1.values.reduce(0, +) }) / Double(max(1, comments.count)))
        roots = Dictionary(comments.filter(\.isTopLevel).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func sourceComments(in video: VideoComments) -> [StoredComment] {
        var seen = Set<String>()
        return video.comments.filter { seen.insert($0.id).inserted }
    }

    func comment(_ number: Int) -> StoredComment? {
        comments.indices.contains(number - 1) ? comments[number - 1] : nil
    }

    func number(for id: String) -> Int? { comments.firstIndex { $0.id == id }.map { $0 + 1 } }

    func validate(_ findings: [Finding], in batch: Batch? = nil) throws -> [Finding] {
        for finding in findings {
            guard !finding.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !finding.evidence.isEmpty else {
                throw failure("Модель вернула вывод без подтверждающих цитат.")
            }
            for item in finding.evidence {
                guard !item.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let source = comment(item.source),
                      source.text.range(of: item.quote, options: .caseInsensitive) != nil,
                      batch == nil || batch!.fragments.contains(where: {
                          $0.number == item.source && $0.text.range(of: item.quote, options: .caseInsensitive) != nil
                      }) else { throw failure("Модель вернула отсутствующий источник или неточную цитату.") }
            }
        }
        return findings
    }

    /// BM25: редкие термины важнее частых; лайки — только разрешение ничьей.
    func search(queries: [String], preferred: [Int] = [], limit: Int = 80) -> [Int] {
        let queryWords = Set(queries.flatMap(Self.tokens))
        let phrases = queries.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru")) }
        let preferred = Set(preferred.filter { comment($0) != nil })
        let scored = comments.indices.compactMap { index -> (Int, Double)? in
            let document = documents[index]
            let length = Double(document.values.reduce(0, +))
            var score = 0.0
            for word in queryWords {
                let count = Double(document[word] ?? 0)
                guard count > 0 else { continue }
                let df = Double(frequencies[word] ?? 0)
                let idf = log(1 + (Double(comments.count) - df + 0.5) / (df + 0.5))
                score += idf * count * 2.2 / (count + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
            let text = (comments[index].author + " " + comments[index].text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru"))
            if phrases.contains(where: { $0.count > 3 && text.contains($0) }) { score += 4 }
            if preferred.contains(index + 1) { score += 1 }
            return score > 0 ? (index + 1, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let left = comments[$0.0 - 1], right = comments[$1.0 - 1]
            if left.likeCount != right.likeCount { return left.likeCount > right.likeCount }
            return $0.0 < $1.0
        }
        // Сначала разные треды, затем оставшиеся совпадения. Нулевые совпадения не подменяем популярными.
        var threads = Set<String>()
        var first: [Int] = [], rest: [Int] = []
        for (number, _) in scored {
            if threads.insert(comments[number - 1].threadId).inserted { first.append(number) }
            else { rest.append(number) }
        }
        return Array((first + rest).prefix(limit))
    }

    func selection(numbers: [Int], queries: [String], expandThreads: [Int] = [], budget: Int = 18000) -> Batch {
        var ordered: [Int] = []
        for number in numbers {
            ordered.append(number)
            if let source = comment(number), !source.isTopLevel, let rootNumber = self.number(for: source.threadId) {
                ordered.append(rootNumber)
            }
        }
        let ranked = expandThreads.isEmpty ? [] : search(queries: queries, limit: comments.count)
        for number in expandThreads.prefix(4) {
            guard let source = comment(number) else { continue }
            // При явном раскрытии не ограничиваемся первыми двумя ответами.
            let replies = ranked.filter { comment($0)?.threadId == source.threadId }
            let other = comments.indices.filter { comments[$0].threadId == source.threadId }.map { $0 + 1 }
            ordered = [number] + replies + other + ordered
        }
        var seen = Set<Int>(), fragments: [Fragment] = []
        var remaining = budget
        let words = queries.flatMap(Self.tokens)
        for number in ordered {
            guard seen.insert(number).inserted, let source = comment(number), remaining > 300 else { continue }
            let maxLength = min(2400, remaining - 250)
            let hits = words.compactMap { source.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            let hit = hits.min { $0.lowerBound < $1.lowerBound }
            let start = hit.flatMap { source.text.index($0.lowerBound, offsetBy: -250, limitedBy: source.text.startIndex) } ?? source.text.startIndex
            let excerpt = String(source.text[start...].prefix(maxLength))
            let text = (start == source.text.startIndex ? "" : "[начало опущено] ") + excerpt
                + (source.text.distance(from: start, to: source.text.endIndex) > maxLength ? " [конец опущен]" : "")
            let fragment = Fragment(number: number, text: text)
            fragments.append(fragment)
            remaining -= format(fragment).count + 2
        }
        return batch(fragments)
    }

    /// Все символы каждого комментария попадают в порции; большой Thread сохраняет контекст корня.
    func batches(budget: Int = 14000) -> [Batch] {
        let grouped = Dictionary(grouping: comments.indices, by: { comments[$0].threadId })
        var ordered: [Int] = [], seenThreads = Set<String>()
        for source in comments where seenThreads.insert(source.threadId).inserted {
            ordered += (grouped[source.threadId] ?? []).sorted {
                if comments[$0].isTopLevel != comments[$1].isTopLevel { return comments[$0].isTopLevel }
                return comments[$0].publishedAt < comments[$1].publishedAt
            }
        }
        var result: [Batch] = [], current: [Fragment] = [], size = 0
        for index in ordered {
            let text = comments[index].text
            var start = text.startIndex
            repeat {
                let end = text.index(start, offsetBy: min(7000, max(1, budget - 1000)), limitedBy: text.endIndex) ?? text.endIndex
                let fragment = Fragment(number: index + 1, text: String(text[start..<end]))
                let length = format(fragment).count + 2
                if size + length > budget, !current.isEmpty {
                    result.append(batch(current)); current = []; size = 0
                }
                current.append(fragment); size += length
                start = end
            } while start < text.endIndex
        }
        if !current.isEmpty { result.append(batch(current)) }
        return result
    }

    private func batch(_ fragments: [Fragment]) -> Batch {
        Batch(fragments: fragments, text: fragments.map(format).joined(separator: "\n\n"))
    }

    private func format(_ fragment: Fragment) -> String {
        guard let source = comment(fragment.number) else { return "" }
        let parent = source.isTopLevel ? nil : roots[source.threadId]
        let context = parent.map { "\nКонтекст корня (не источник цитаты): \(String($0.text.prefix(300)))" } ?? ""
        return "[\(fragment.number)] id=\(source.id), thread=\(source.threadId), автор=\(source.author.prefix(80)), лайков=\(source.likeCount)\(context)\nТЕКСТ: \(fragment.text)"
    }

    static func tokens(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        let stop: Set<String> = ["что", "это", "как", "для", "про", "или", "все", "его", "она", "они", "мне", "меня", "тут", "там", "есть", "нет", "кто", "чем", "этом", "этого", "какие", "какой", "почему", "расскажи", "подробнее", "комментарии", "комментариях", "саммари", "сказал", "можно", "только", "вообще", "было", "были", "the", "and", "what", "about"]
        var result: [String] = []
        tagger.enumerateTags(in: tagger.string!.startIndex..<tagger.string!.endIndex, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = tag?.rawValue ?? String(tagger.string![range])
            guard word.count >= 2, !stop.contains(word) else { return true }
            // Fallback для русских форм, если системный словарь не вернул лемму.
            let endings = ["иями", "ами", "ями", "ого", "ему", "ыми", "ими", "иях", "ах", "ях", "ов", "ев", "ом", "ем", "ам", "ям", "ой", "ый", "ий", "ая", "яя", "ое", "ее", "ые", "ие", "ы", "и", "а", "я", "у", "ю", "е"]
            if word.range(of: "^[а-я]+$", options: .regularExpression) != nil,
               let ending = endings.first(where: { word.hasSuffix($0) && word.count - $0.count >= 4 }) {
                result.append(String(word.dropLast(ending.count)))
            } else { result.append(word) }
            return true
        }
        return result
    }
}
