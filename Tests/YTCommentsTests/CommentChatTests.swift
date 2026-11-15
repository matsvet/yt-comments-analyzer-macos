import Foundation
import Testing
@testable import YTComments

@MainActor
@Suite("Comment-grounded chat", .serialized)
struct CommentChatTests {
    private func comment(_ id: String, text: String, thread: String? = nil, likes: Int = 0) -> StoredComment {
        StoredComment(id: id, threadId: thread ?? id, isTopLevel: thread == nil,
                      author: "author-" + id, authorChannelId: nil, text: text,
                      likeCount: likes, publishedAt: .distantPast, totalReplyCount: 0)
    }

    @Test func retrievesUnpopularEvidenceAndItsThreadWithinBudget() {
        let popular = (0..<100).map { comment("p\($0)", text: String(repeating: "Реклама отличная. ", count: 100), likes: 1000) }
        let root = comment("rare", text: "Я работаю в другом отделе")
        let reply = comment("reply", text: String(repeating: "Предыстория. ", count: 200) + "Зарплаты сварщиков: 80000 рублей", thread: "rare")
        let video = VideoComments(videoId: "one", fetchedAt: .now, comments: popular + [root, reply])
        let context = CommentChatContext(video: video, question: "Что пишут о сварщиках?")
        #expect(context.comments.first?.id == "reply")
        #expect(context.comments.contains { $0.id == "rare" })
        #expect(context.text.contains("80000"))
        #expect(context.text.count < 6800)
        #expect(Set(context.comments.map(\.id)).count == context.comments.count)
        let other = CommentChatContext(video: VideoComments(videoId: "two", fetchedAt: .now, comments: []), question: "сварщики")
        #expect(other.comments.isEmpty)
        #expect(!other.text.contains("80000"))
    }

    @Test func rejectsInventedSourcesAndFailsClosedWithoutEvidence() throws {
        let sources = [comment("a", text: "Учусь на сварщика")]
        let valid = try CommentChatState.decodeAnswer(#"{"answer":"**Автор учится на сварщика** [1]","sources":[1,1]}"#, sources: sources)
        #expect(valid.answer == "Автор учится на сварщика [1]")
        #expect(valid.numbers == [1])
        #expect(valid.sources.map(\.id) == ["a"])
        for id in [0, -1, 2, Int.min] {
            #expect(throws: LLMError.self) {
                try CommentChatState.decodeAnswer("{\"answer\":\"invented\",\"sources\":[\(id)]}", sources: sources)
            }
        }
        let unsupported = try CommentChatState.decodeAnswer(#"{"answer":"Invented external fact","sources":[]}"#, sources: sources)
        #expect(!unsupported.answer.contains("Invented"))
        #expect(unsupported.sources.isEmpty)
    }

    @Test func retriesOnceAfterProviderRateLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ChatProtocol.status = 200; ChatProtocol.headers = [:] }
        let endpoint = try #require(URL(string: "https://example.com/v1/chat/completions"))
        let client = LLMClient(session: session, chatEndpoint: endpoint, apiKey: "test")
        let chat = CommentChatState()
        let video = VideoComments(videoId: "retry", fetchedAt: .now, comments: [comment("r", text: "Отличная клавиатура")])
        var attempts = 0
        ChatProtocol.handler = { request in
            attempts += 1
            ChatProtocol.status = attempts == 1 ? 429 : 200
            ChatProtocol.headers = ["Retry-After": "0.01"]
            let response = try Self.reply(for: request, quote: "Отличная клавиатура")
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": response]]]])
        }
        chat.draft = "Что о клавиатуре?"
        chat.send(video: video, summary: nil, client: client, model: "test")
        for _ in 0..<200 {
            if !chat.isSending { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(attempts == 4) // 429 + повтор плана + ответ + проверка
        #expect(chat.turns.last?.answer != nil)
        #expect(chat.turns.last?.error == nil)
    }

    @Test func multiTurnHistoryAndVideoIsolation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let endpoint = try #require(URL(string: "https://example.com/v1/chat/completions"))
        let client = LLMClient(session: session, chatEndpoint: endpoint, apiKey: "test")
        let chat = CommentChatState()
        let videoA = VideoComments(videoId: "a", fetchedAt: .now, comments: [comment("a1", text: "Сварщики получают 80000")])
        let videoB = VideoComments(videoId: "b", fetchedAt: .now, comments: [comment("b1", text: "Клавиатура удобная")])
        ChatProtocol.handler = { request in
            let data = try #require(request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let size = stream.read(&buffer, maxLength: buffer.count)
                    if size <= 0 { break }
                    data.append(contentsOf: buffer.prefix(size))
                }
                return data
            })
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.first?["role"] == "system")
            #expect((json["response_format"] as? [String: String])?["type"] == "json_object")
            let last = messages.last?["content"] ?? ""
            if last.contains("поясни") {
                #expect(messages.contains { ($0["content"] ?? "").contains("Что о сварщиках?") })
            }
            if last.contains("клавиатуре") {
                #expect(!messages.contains { ($0["content"] ?? "").contains("80000") })
            }
            var replay = request
            replay.httpBody = data
            let response = try Self.reply(for: replay, quote: last.contains("клавиатуре") ? "Клавиатура удобная" : "Сварщики получают 80000")
            let body: [String: Any] = ["choices": [["message": ["content": response]]]]
            return try JSONSerialization.data(withJSONObject: body)
        }
        chat.selectVideo("a")
        chat.draft = "Что о сварщиках?"
        chat.send(video: videoA, summary: nil, client: client, model: "test")
        try await finish(chat)
        #expect(chat.turns.count == 1)
        #expect(chat.turns[0].answer != nil)
        chat.draft = "поясни"
        chat.send(video: videoA, summary: nil, client: client, model: "test")
        try await finish(chat)
        #expect(chat.turns.count == 2)
        chat.selectVideo("b")
        #expect(chat.turns.isEmpty)
        chat.draft = "Что о клавиатуре?"
        chat.send(video: videoB, summary: nil, client: client, model: "test")
        try await finish(chat)
        chat.selectVideo("a")
        #expect(chat.turns.count == 2)
        chat.clear()
        chat.selectVideo("b")
        #expect(chat.turns.count == 1)
        chat.selectVideo("a")
        #expect(chat.turns.isEmpty)

        chat.draft = "pending"
        chat.send(video: videoA, summary: nil, client: client, model: "test")
        chat.selectVideo("b")
        try await Task.sleep(for: .milliseconds(30))
        #expect(chat.videoID == "b")
        #expect(chat.turns.count == 1)
        #expect(!chat.isSending)
        chat.selectVideo("a")
        #expect(chat.turns.last?.error != nil)
        #expect(chat.turns.last?.answer == nil)
        chat.prepareRetry()
        #expect(chat.draft == "pending")
        #expect(chat.turns.isEmpty)
    }

    private static func reply(for request: URLRequest, quote: String) throws -> String {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? read(request.httpBodyStream)) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        let system = messages.first?["content"] ?? ""
        if system.contains("Спланируй поиск") {
            return #"{"mode":"search","queries":[],"criterion":null,"exactPhrase":null,"countUnit":"comments"}"#
        }
        if system.contains("Проверь каждый вывод") { return #"{"supported":[1]}"# }
        return String(data: try JSONSerialization.data(withJSONObject: ["claims": [["text": "По комментарию", "evidence": [["source": 1, "quote": quote]]]], "sufficient": true, "searchQueries": [], "readThreads": []]), encoding: .utf8)!
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let size = stream.read(&bytes, maxLength: bytes.count)
            if size <= 0 { break }
            data.append(contentsOf: bytes.prefix(size))
        }
        return data
    }

    private func finish(_ chat: CommentChatState) async throws {
        for _ in 0..<100 {
            if !chat.isSending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Chat did not finish")
    }
}

private final class ChatProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> Data)?
    static var status = 200
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let url = try #require(request.url)
            let data = try handler(request)
            let response = try #require(HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
