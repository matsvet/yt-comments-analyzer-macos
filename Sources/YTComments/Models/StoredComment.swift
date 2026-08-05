import Foundation

/// Один комментарий в плоском виде.
/// Корень треда: `isTopLevel == true`, `threadId == id`.
/// Ответ: `isTopLevel == false`, `threadId` указывает на корень.
struct StoredComment: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let isTopLevel: Bool
    let author: String
    let authorChannelId: String?
    let text: String
    let likeCount: Int
    let publishedAt: Date
    /// Осмысленно только для корня треда (для ответов = 0).
    let totalReplyCount: Int
}

/// Глубокий модуль Thread navigation.
/// Ранее shallow и разбросан: flat invariant в docs StoredComment, root/replies/selectThread в AppState (280+), 
/// onTap/isActive в ResultsListView, root+replies в ThreadDetailView, isTopLevel checks в CommentRow.
/// Теперь: явный struct Thread с маленьким интерфейсом (factory from flat list + root/replies).
/// Увеличивает depth (small interface, большая impl внутри), locality (всё знание thread в одном модуле),
/// leverage (Views и тесты используют Thread, не знают про flat-инвариант напрямую),
/// deletion test теперь проходит лучше (сложность концентрируется здесь, не переползает в 5 модулей).
struct Thread: Equatable, Hashable {
    let root: StoredComment
    let replies: [StoredComment]
}

extension Thread {
    /// Factory из плоского списка (flat representation).
    /// Гарантирует (строго по flat invariant): root.isTopLevel && root.id == root.threadId == threadId;
    /// replies: !isTopLevel && .threadId == root.id, отсортированы chronologically по publishedAt.
    /// Используется AppState и Views. (Thread navigation module)
    static func from(comments: [StoredComment], threadId: String) -> Thread? {
        // Enforce full flat invariant for thread root: isTopLevel && threadId == id (see StoredComment docs and glossary: "a thread root has `isTopLevel == true` and `threadId == id`"; "flat comments list always (no nested tree)").
        guard let root = comments.first(where: { $0.id == threadId && $0.isTopLevel && $0.threadId == threadId }) else { return nil }
        let replies = comments
            .filter { !$0.isTopLevel && $0.threadId == threadId }
            .sorted { $0.publishedAt < $1.publishedAt }
        return Thread(root: root, replies: replies)
    }
}

/// Глубокий модуль Offline Search.
/// Ранее: searchResults + makeMatcher + fields + regex/wholeWord buried inside большого AppState (shallow interface с 6+ search-related публичными членами).
/// Тесты вынуждены были строить полный AppState.
/// Теперь: маленький интерфейс SearchConfig + pure func search(...) -> [StoredComment] (и topLevel helper).
/// Улучшает: locality (логика matcher/sort? в одном месте), leverage (прямые unit тесты на search без state; готово для semantic search в будущем),
/// shrinks interface AppState (делегирует), deletion test для search-логики теперь фокусирован.
/// Sort остаётся в AppState (т.к. tied к sortOrder UI), но matching pure.
struct SearchConfig: Equatable {
    let matchCase: Bool
    let wholeWord: Bool
    let searchAuthors: Bool
}

/// Чистая функция поиска по плоскому списку комментариев.
/// Пустой query -> только top-level (для sortedTopLevels callers).
/// Не выполняет сортировку (caller применяет sorted по SortOrder).
func search(comments: [StoredComment], config: SearchConfig, query: String) -> [StoredComment] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else {
        return topLevelComments(in: comments)
    }

    let includeAuthor = config.searchAuthors

    let matcher: (StoredComment) -> Bool
    if config.wholeWord {
        let escaped = NSRegularExpression.escapedPattern(for: q)
        var options: NSRegularExpression.Options = []
        if !config.matchCase { options.insert(.caseInsensitive) }
        let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: options)
        matcher = { comment in
            fields(of: comment, includeAuthor: includeAuthor).contains { field in
                guard let regex else { return false }
                let range = NSRange(field.startIndex..., in: field)
                return regex.firstMatch(in: field, range: range) != nil
            }
        }
    } else if config.matchCase {
        matcher = { comment in
            fields(of: comment, includeAuthor: includeAuthor).contains { $0.contains(q) }
        }
    } else {
        matcher = { comment in
            fields(of: comment, includeAuthor: includeAuthor).contains {
                $0.localizedCaseInsensitiveContains(q)
            }
        }
    }
    return comments.filter(matcher)
}

/// Вспомогательный чистый helper для top-level (используется search и sortedTopLevels в AppState).
func topLevelComments(in comments: [StoredComment]) -> [StoredComment] {
    comments.filter(\.isTopLevel)
}

private func fields(of comment: StoredComment, includeAuthor: Bool) -> [String] {
    includeAuthor ? [comment.text, comment.author] : [comment.text]
}
