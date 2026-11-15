import Foundation

/// Совместимый локальный вход в общий корпус источников.
struct CommentChatContext {
    let comments: [StoredComment]
    let text: String

    init(video: VideoComments, question: String, previousQuestion: String = "", previousSources: [StoredComment] = []) {
        let corpus = CommentCorpus(video: video)
        let preferred = previousSources.compactMap { corpus.number(for: $0.id) }
        let queries = [question, previousQuestion].filter { !$0.isEmpty }
        let numbers = corpus.search(queries: queries, preferred: preferred)
        let batch = corpus.selection(numbers: numbers, queries: queries, budget: 6500)
        comments = batch.fragments.compactMap { corpus.comment($0.number) }
        text = "Передано \(comments.count) из \(corpus.comments.count) комментариев. Это найденные фрагменты, не вся дискуссия.\n\n" + batch.text
    }
}
