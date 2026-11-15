import Foundation
import Testing
@testable import YTComments

@Suite("Full comment analysis", .serialized)
struct CommentAnalysisTests {
    private func comment(_ id: String, _ text: String, thread: String? = nil, author: String? = nil) -> StoredComment {
        StoredComment(id: id, threadId: thread ?? id, isTopLevel: thread == nil, author: id,
                      authorChannelId: author, text: text, likeCount: 0, publishedAt: .distantPast, totalReplyCount: 0)
    }

    @Test func completePartitionAndStableEvidence() throws {
        let long = String(repeating: "Очень длинный ответ 🐈. ", count: 1500) + "Редкое возражение в конце."
        let root = comment("root", "Главная тема")
        let video = VideoComments(videoId: "test", fetchedAt: .now, comments: [root, comment("reply", long, thread: "root"), root])
        let corpus = CommentCorpus(video: video)
        #expect(corpus.comments.count == 2)
        let batches = corpus.batches()
        #expect(batches.count > 1)
        let reconstructed = batches.flatMap(\.fragments).filter { $0.number == 2 }.map(\.text).joined()
        #expect(reconstructed == long)
        #expect(Set(batches.flatMap(\.fragments).map(\.number)) == [1, 2])
        #expect(batches.allSatisfy { $0.text.count <= 14000 })
        let evidence = CommentCorpus.Finding(text: "Возражение", evidence: [.init(source: 2, quote: "Редкое возражение в конце.")])
        #expect(try corpus.validate([evidence]).count == 1)
        #expect(throws: LLMError.self) { try corpus.validate([evidence], in: batches[0]) }
        #expect(throws: LLMError.self) {
            try corpus.validate([.init(text: "Выдумка", evidence: [.init(source: 999, quote: "Выдумка")])])
        }
        #expect(throws: LLMError.self) {
            try corpus.validate([.init(text: "Выдумка", evidence: [.init(source: 1, quote: "Не было такого")])])
        }
    }

    @Test func retrievalExpansionNoPopularityFallbackAndLateReply() {
        let video = VideoComments(videoId: "search", fetchedAt: .now, comments: [
            comment("one", "Цена курса слишком высокая"),
            comment("two", "Очень дорого, переплата"),
            comment("root", "Ветка про транспорт"),
            comment("a", "Первый ответ", thread: "root"),
            comment("b", "Второй ответ", thread: "root"),
            comment("c", "Позднее возражение: автобус быстрее", thread: "root")
        ])
        let corpus = CommentCorpus(video: video)
        let literal = corpus.search(queries: ["стоимость"])
        #expect(literal.isEmpty)
        let expanded = corpus.search(queries: ["стоимость", "цена", "дорого", "переплата"])
        #expect(expanded.contains(1) && expanded.contains(2))
        #expect(corpus.search(queries: ["несуществующееслово"]).isEmpty)
        let batch = corpus.selection(numbers: [3], queries: ["автобус"], expandThreads: [3])
        #expect(batch.numbers.contains(6))
        #expect(batch.text.contains("автобус быстрее"))
    }

    @Test func pipelineResumesFailedPortionAndCachesBySnapshotAndConfiguration() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "all", fetchedAt: .now, comments: (1...4).map {
            comment("c\($0)", String(repeating: "Факт \($0). ", count: 1000))
        })
        let corpus = CommentCorpus(video: video)
        let batches = corpus.batches()
        #expect(batches.count > 1)
        var calls = 0, extractions = 0, fail = true
        AnalysisProtocol.handler = { system, user in
            calls += 1
            if system.contains("Извлеки содержательные") {
                extractions += 1
                if fail && extractions == 2 { throw URLError(.networkConnectionLost) }
                return try extraction(for: user)
            }
            if system.contains("Проверь каждый вывод") { return #"{"supported":[1]}"# }
            return try draft(source: 1, quote: "Факт 1.")
        }
        await #expect(throws: LLMError.self) {
            try await engine.summarize(video: video, client: client, model: "test", configuration: "one", progress: { _ in })
        }
        fail = false
        let result = try await engine.summarize(video: video, client: client, model: "test", configuration: "one", progress: { _ in })
        #expect(result.total == 4 && result.portions == batches.count)
        #expect(extractions == batches.count + 1) // Успешная первая порция не запрашивается повторно.
        let oldCalls = calls
        _ = try await engine.summarize(video: video, client: client, model: "test", configuration: "one", progress: { _ in })
        #expect(calls == oldCalls)
        _ = try await engine.summarize(video: video, client: client, model: "test", configuration: "two", progress: { _ in })
        #expect(calls > oldCalls)
        var revised = video
        revised.comments[0] = comment("c1", "Факт 1. Изменённый текст")
        #expect(CommentCorpus(video: revised).key != corpus.key)
    }

    @Test func boundedSecondSearchAndSemanticVerification() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "search", fetchedAt: .now, comments: [comment("a", "Слишком дорого")])
        var answers = 0, verification = 0
        AnalysisProtocol.handler = { system, user in
            if system.contains("Спланируй поиск") { return plan(mode: "search", queries: ["стоимость"]) }
            if system.contains("Проверь каждый вывод") {
                verification += 1
                #expect(user.contains("Слишком дорого"))
                return #"{"supported":[1]}"#
            }
            answers += 1
            if answers == 1 {
                #expect(!user.contains("ТЕКСТ: Слишком дорого"))
                return #"{"claims":[],"sufficient":false,"searchQueries":["дорого"],"readThreads":[]}"#
            }
            #expect(user.contains("Слишком дорого"))
            return try draft(source: 1, quote: "Слишком дорого")
        }
        let answer = try await engine.answer(video: video, question: "Что о стоимости?", history: "", previousSources: [], client: client, model: "test", configuration: "x", progress: { _ in })
        #expect(answers == 2 && verification == 1)
        #expect(answer.evidence.first?.source == 1)
        #expect(answer.scanned == 1 && answer.analyzed == 1 && !answer.complete)
        AnalysisProtocol.handler = { system, _ in
            if system.contains("Спланируй поиск") { return plan(mode: "search", queries: ["дорого"]) }
            if system.contains("Проверь каждый вывод") { return #"{"supported":[]}"# }
            return try draft(source: 1, quote: "Слишком дорого")
        }
        await #expect(throws: LLMError.self) {
            try await engine.answer(video: video, question: "Цена?", history: "", previousSources: [], client: client, model: "test", configuration: "x", progress: { _ in })
        }
    }

    @Test func countsUniqueCommentsAndAuthorsWithoutInventingTotals() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let video = VideoComments(videoId: "count", fetchedAt: .now, comments: [
            comment("one", "дорого дорого", author: "channel"), comment("two", "дорого", author: "channel"), comment("three", "дёшево")
        ])
        let engine = CommentAnalysis()
        var calls = 0
        AnalysisProtocol.handler = { system, _ in
            calls += 1
            #expect(system.contains("Спланируй поиск"))
            return plan(mode: "count", queries: [], criterion: "буквальная фраза", exact: "дорого")
        }
        let result = try await engine.answer(video: video, question: "Сколько комментариев с фразой «дорого»?", history: "", previousSources: [], client: client, model: "test", configuration: "x", progress: { _ in })
        #expect(calls == 1)
        #expect(result.text.contains("комментариев: 2 из 3"))
        #expect(result.complete && result.analyzed == 3)
        AnalysisProtocol.handler = { system, _ in
            if system.contains("Спланируй поиск") { return plan(mode: "count", queries: [], criterion: "жалоба на цену", unit: "authors") }
            return #"{"matches":[{"source":1,"quote":"дорого"},{"source":1,"quote":"дорого"},{"source":2,"quote":"дорого"}]}"#
        }
        let authors = try await engine.answer(video: video, question: "Сколько авторов жалуется?", history: "", previousSources: [], client: client, model: "test", configuration: "x", progress: { _ in })
        #expect(authors.text.contains("авторов: 1"))
        #expect(authors.text.contains("может ошибаться"))
    }

    @Test func forcedOverviewProcessesEveryPortion() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "overview", fetchedAt: .now, comments: (1...4).map {
            comment("c\($0)", String(repeating: "Факт \($0). ", count: 1000))
        })
        let batches = CommentCorpus(video: video).batches()
        var portions = 0
        AnalysisProtocol.handler = { system, user in
            if system.contains("Спланируй поиск") { return plan(mode: "search", queries: ["факт"]) }
            if system.contains("Извлеки содержательные") { portions += 1; return try extraction(for: user) }
            if system.contains("Проверь каждый вывод") { return #"{"supported":[1]}"# }
            return try draft(source: 1, quote: "Факт 1.")
        }
        let result = try await engine.answer(video: video, question: "Какой факт?", history: "", previousSources: [], client: client, model: "test", configuration: "x", fullScan: true, progress: { _ in })
        #expect(portions == batches.count)
        #expect(result.complete && result.analyzed == 4)
    }

    @Test func shortSummarySkipsExtractionAndRejectsOversizedFinal() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "small", fetchedAt: .now, comments: [comment("one", "Факт")])
        var calls = 0
        AnalysisProtocol.handler = { system, _ in
            calls += 1
            #expect(!system.contains("Извлеки содержательные"))
            if system.contains("Проверь каждый вывод") { return #"{"supported":[1]}"# }
            return try draft(source: 1, quote: "Факт")
        }
        _ = try await engine.summarize(video: video, client: client, model: "test", configuration: "x", progress: { _ in })
        #expect(calls == 2)
        calls = 0
        AnalysisProtocol.handler = { _, _ in
            calls += 1
            return try draft(source: 1, quote: "Факт").replacingOccurrences(of: "Подтверждённый вывод", with: String(repeating: "слово ", count: 181))
        }
        await #expect(throws: LLMError.self) {
            try await engine.summarize(video: video, client: client, model: "test", configuration: "y", progress: { _ in })
        }
        #expect(calls == 2) // один черновик + ровно одна попытка сокращения
    }

    @Test func countWithNegationCannotUseLiteralShortcut() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "negative", fetchedAt: .now, comments: [comment("one", "дорого"), comment("two", "Прекрасно")])
        var classifications = 0
        AnalysisProtocol.handler = { system, _ in
            if system.contains("Спланируй поиск") {
                return plan(mode: "count", queries: [], criterion: "Не содержит фразу дорого", exact: "дорого")
            }
            classifications += 1
            return #"{"matches":[{"source":2,"quote":"Прекрасно"}]}"#
        }
        let result = try await engine.answer(video: video, question: "Сколько комментариев НЕ содержат «дорого»?", history: "", previousSources: [], client: client, model: "test", configuration: "x", progress: { _ in })
        #expect(classifications == 1)
        #expect(result.evidence.first?.source == 2)
        #expect(result.text.contains("комментариев: 1 из 2"))
    }

    @Test func reductionKeepsOnlyExistingSourceQuotes() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "reduce", fetchedAt: .now, comments: (1...28).map {
            comment("c\($0)", String(repeating: "Факт \($0). ", count: 850))
        })
        var reductions = 0
        AnalysisProtocol.handler = { system, user in
            if system.contains("Объедини заметки") {
                reductions += 1
                let object = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
                let first = (object["findings"] as! [[String: Any]])[0]
                var evidence = (first["evidence"] as! [[String: Any]])[0]
                evidence["quote"] = String((evidence["quote"] as! String).prefix(100))
                return String(data: try JSONSerialization.data(withJSONObject: ["findings": [["text": "Сводная тема", "evidence": [evidence]]]]), encoding: .utf8)!
            }
            if system.contains("Извлеки содержательные") {
                let raw = try extraction(for: user)
                var object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
                var first = (object["findings"] as! [[String: Any]])[0]
                first["text"] = String(repeating: "тема ", count: 95)
                var evidence = (first["evidence"] as! [[String: Any]])[0]
                let regex = try NSRegularExpression(pattern: #"ТЕКСТ: ([^\n]+)"#)
                let match = try #require(regex.firstMatch(in: user, range: NSRange(user.startIndex..., in: user)))
                evidence["quote"] = String((user as NSString).substring(with: match.range(at: 1)).prefix(280))
                first["evidence"] = [evidence]
                object["findings"] = [first]
                return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }
            if system.contains("Проверь каждый вывод") { return #"{"supported":[1]}"# }
            let notes = user.components(separatedBy: "Заметки:\n").last!
            let object = try JSONSerialization.jsonObject(with: Data(notes.utf8)) as! [String: Any]
            let first = (object["findings"] as! [[String: Any]])[0]
            let evidence = (first["evidence"] as! [[String: Any]])[0]
            return try draft(source: evidence["source"] as! Int, quote: evidence["quote"] as! String)
        }
        let result = try await engine.summarize(video: video, client: client, model: "test", configuration: "x", progress: { _ in })
        #expect(reductions > 0)
        #expect(result.total == 28)
        #expect(!result.evidence.isEmpty)
    }

    @Test func cancellationStopsBeforeCallingModel() async throws {
        let (client, session) = client()
        defer { session.invalidateAndCancel(); AnalysisProtocol.handler = nil }
        let engine = CommentAnalysis()
        let video = VideoComments(videoId: "cancel", fetchedAt: .now, comments: [comment("one", "Факт")])
        AnalysisProtocol.handler = { _, _ in Issue.record("Отменённый запрос дошёл до модели"); return "{}" }
        let task = Task {
            try await engine.summarize(video: video, client: client, model: "test", configuration: "x", progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func client() -> (LLMClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalysisProtocol.self]
        let session = URLSession(configuration: config)
        return (LLMClient(session: session, chatEndpoint: URL(string: "https://example.com/v1/chat/completions")!, apiKey: "test"), session)
    }
}

private func plan(mode: String, queries: [String], criterion: String? = nil, exact: String? = nil, unit: String = "comments") -> String {
    let value: [String: Any] = ["mode": mode, "queries": queries, "criterion": criterion as Any? ?? NSNull(), "exactPhrase": exact as Any? ?? NSNull(), "countUnit": unit]
    return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

private func draft(source: Int, quote: String) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: ["claims": [["text": "Подтверждённый вывод", "evidence": [["source": source, "quote": quote]]]], "sufficient": true, "searchQueries": [], "readThreads": []]), encoding: .utf8)!
}

private func extraction(for user: String) throws -> String {
    let regex = try NSRegularExpression(pattern: #"\[(\d+)\] id=.*?ТЕКСТ: ([^\n]+)"#, options: [.dotMatchesLineSeparators])
    let match = try #require(regex.firstMatch(in: user, range: NSRange(user.startIndex..., in: user)))
    let source = Int((user as NSString).substring(with: match.range(at: 1)))!
    let text = String((user as NSString).substring(with: match.range(at: 2)).prefix(7))
    return String(data: try JSONSerialization.data(withJSONObject: ["findings": [["text": "Факт", "evidence": [["source": source, "quote": text]]]]]), encoding: .utf8)!
}

private final class AnalysisProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((String, String) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: String]])
            let handler = try #require(Self.handler)
            let answer = try handler(messages.first?["content"] ?? "", messages.last?["content"] ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": answer]]]])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
