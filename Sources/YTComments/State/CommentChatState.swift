import Foundation
import Observation

/// Диалог и его источники хранятся только в памяти, отдельно для каждого видео.
@Observable
@MainActor
final class CommentChatState {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var sources: [StoredComment] = []
        var sourceNumbers: [Int] = []
        var sourceQuotes: [String] = []
        var scannedComments = 0
        var analyzedComments = 0
        var completeAnalysis = false
        var totalComments = 0
        var searchedComments = 0
        var error: String?
    }

    private(set) var videoID: String?
    private(set) var turns: [Turn] = []
    private(set) var isSending = false
    var draft = ""
    var fullScan = false
    private(set) var statusMessage = "Ищу ответ в комментариях…"
    private var sessions: [String: [Turn]] = [:]
    private var task: Task<Void, Never>?

    func selectVideo(_ id: String?) {
        guard id != videoID else { return }
        cancel()
        if let videoID { sessions[videoID] = turns }
        videoID = id
        turns = id.flatMap { sessions[$0] } ?? []
        draft = ""
    }

    func clear() {
        cancel()
        turns = []
        draft = ""
        if let videoID { sessions.removeValue(forKey: videoID) }
    }

    func forgetVideo(_ id: String) {
        if videoID == id { clear() }
        sessions.removeValue(forKey: id)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSending = false
        if let last = turns.indices.last, turns[last].answer == nil, turns[last].error == nil {
            turns[last].error = "Ответ отменён. Можно повторить вопрос."
        }
    }

    func prepareRetry() {
        guard let last = turns.last, last.error != nil else { return }
        draft = last.question
        turns.removeLast()
    }

    func send(video: VideoComments, summary: String?, client: LLMClient, model: String,
              analysis: CommentAnalysis = CommentAnalysis(), configuration: String = "default") {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !question.isEmpty, question.count <= 1500, !video.comments.isEmpty else { return }
        selectVideo(video.videoId)
        let history = Array(turns.filter { $0.answer != nil }.suffix(2))
        let historyText = history.map { "Вопрос: \($0.question)\nОтвет: \(String(($0.answer ?? "").prefix(1500)))" }.joined(separator: "\n")
        let previousSources = history.last?.sources ?? []
        let scanAll = fullScan
        let turn = Turn(question: question, totalComments: video.comments.count)
        turns.append(turn)
        draft = ""
        isSending = true
        statusMessage = "Ищу ответ в комментариях…"
        task = Task { [weak self] in
            do {
                let response = try await analysis.answer(video: video, question: question, history: historyText,
                                                         previousSources: previousSources, client: client, model: model,
                                                         configuration: configuration, fullScan: scanAll) { [weak self] status in
                    guard let self, self.turns.last?.id == turn.id else { return }
                    self.statusMessage = status
                }
                try Task.checkCancellation()
                guard let self, self.videoID == video.videoId, self.turns.last?.id == turn.id else { return }
                let sourceComments = CommentCorpus.sourceComments(in: video)
                var numbers: [Int] = []
                for item in response.evidence where !numbers.contains(item.source) { numbers.append(item.source) }
                let index = self.turns.count - 1
                self.turns[index].answer = response.text
                self.turns[index].sources = numbers.compactMap { sourceComments.indices.contains($0 - 1) ? sourceComments[$0 - 1] : nil }
                self.turns[index].sourceNumbers = numbers
                self.turns[index].sourceQuotes = numbers.map { number in response.evidence.filter { $0.source == number }.map(\.quote).joined(separator: " … ") }
                self.turns[index].searchedComments = response.selected
                self.turns[index].scannedComments = response.scanned
                self.turns[index].analyzedComments = response.analyzed
                self.turns[index].completeAnalysis = response.complete
                self.isSending = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.videoID == video.videoId,
                      self.turns.last?.id == turn.id else { return }
                self.turns[self.turns.count - 1].error = error.localizedDescription
                self.isSending = false
                self.task = nil
            }
        }
    }

    /// Ответ без валидных ссылок на переданные комментарии не превращается в ответ «из знаний модели».
    static func decodeAnswer(_ text: String, sources: [StoredComment]) throws -> (answer: String, sources: [StoredComment], numbers: [Int]) {
        struct Response: Decodable { let answer: String; let sources: [Int] }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: Data(text.utf8)) }
        catch { throw LLMError.network("Модель вернула ответ в неверном формате. Повторите вопрос.") }
        let numbers = response.sources.reduce(into: [Int]()) { result, number in
            if !result.contains(number) { result.append(number) }
        }
        guard numbers.allSatisfy({ $0 > 0 && $0 <= sources.count }) else {
            throw LLMError.network("Модель указала отсутствующие источники. Повторите вопрос.")
        }
        guard !numbers.isEmpty else {
            return ("В найденных комментариях нет достаточных данных для ответа. Уточните вопрос или назовите тему, автора либо фразу. Само видео и его расшифровка не загружены.", [], [])
        }
        let answer = response.answer.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LLMError.emptyResponse }
        return (answer, numbers.map { sources[$0 - 1] }, numbers)
    }

}
