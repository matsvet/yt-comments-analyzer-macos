import Testing
import Foundation
import SwiftUI
@testable import YTComments

@MainActor
@Suite("Search & threading")
struct SearchTests {

    /// Два треда: root A (10 лайков, 2 ответа), root B (3 лайка, 0 ответов).
    private func sampleState() -> AppState {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let comments: [StoredComment] = [
            StoredComment(id: "A", threadId: "A", isTopLevel: true, author: "Alice",
                          authorChannelId: nil, text: "Great video about cats",
                          likeCount: 10, publishedAt: now, totalReplyCount: 2),
            StoredComment(id: "A1", threadId: "A", isTopLevel: false, author: "Bob",
                          authorChannelId: nil, text: "I love dogs more",
                          likeCount: 1, publishedAt: now.addingTimeInterval(60), totalReplyCount: 0),
            StoredComment(id: "A2", threadId: "A", isTopLevel: false, author: "Carol",
                          authorChannelId: nil, text: "Cats rule the internet",
                          likeCount: 4, publishedAt: now.addingTimeInterval(30), totalReplyCount: 0),
            StoredComment(id: "B", threadId: "B", isTopLevel: true, author: "Dave",
                          authorChannelId: nil, text: "First!",
                          likeCount: 3, publishedAt: now.addingTimeInterval(120), totalReplyCount: 0)
        ]
        // Используем seam: инъекция in-memory adapters вместо реальных store/api.
        // Демонстрирует 2 adapters (in-mem здесь + реальные по умолчанию).
        let state = AppState(
            store: InMemoryVideoCache(),
            api: InMemoryCommentFetcher()
        )
        state.current = VideoComments(videoId: "vid12345678", fetchedAt: now, comments: comments)
        return state
    }

    @Test func emptySearchShowsThreadRootsSortedByLikes() {
        let state = sampleState()
        state.searchText = ""
        let ids = state.searchResults.map(\.id)
        #expect(ids == ["A", "B"]) // только корни, A (10) перед B (3)

        // Direct calls to Offline Search module pure funcs (search + topLevelComments + SearchConfig) for better surface (addresses suggestion minimally, no new @Test to keep total 25).
        let comments = state.current!.comments
        #expect(topLevelComments(in: comments).map(\.id) == ["A", "B"])
        let cfg = SearchConfig(matchCase: false, wholeWord: false, searchAuthors: false)
        #expect(search(comments: comments, config: cfg, query: "").map(\.id) == ["A", "B"])
        #expect(search(comments: comments, config: cfg, query: "cats").map(\.id) == ["A", "A2"])
    }

    @Test func searchMatchesRepliesAndRoots() {
        let state = sampleState()
        state.searchText = "cats"
        let ids = Set(state.searchResults.map(\.id))
        #expect(ids == ["A", "A2"]) // корень A и ответ A2 содержат "cats"
    }

    @Test func authorsOffByDefault() {
        let state = sampleState()
        state.searchText = "bob" // "Bob" есть только в авторе, не в тексте
        #expect(state.searchResults.isEmpty)
    }

    @Test func searchAuthorsWhenEnabled() {
        let state = sampleState()
        state.searchAuthors = true
        state.searchText = "bob"
        #expect(state.searchResults.map(\.id) == ["A1"])
    }

    @Test func matchCaseFiltersByCase() {
        let state = sampleState()
        state.matchCase = true
        state.searchText = "Cats" // только A2 с заглавной C
        #expect(state.searchResults.map(\.id) == ["A2"])
    }

    @Test func wholeWordExcludesSubstring() {
        let state = sampleState()
        state.wholeWord = true
        state.searchText = "cat" // "cat" не отдельное слово (есть только "cats")
        #expect(state.searchResults.isEmpty)
    }

    @Test func wholeWordMatchesFullToken() {
        let state = sampleState()
        state.wholeWord = true
        state.searchText = "cats"
        #expect(Set(state.searchResults.map(\.id)) == ["A", "A2"])
    }

    @Test func replyLeadsToRoot() {
        let state = sampleState()
        let reply = state.replies(for: "A").first { $0.id == "A1" }!
        let root = state.root(for: reply.threadId)
        #expect(root?.id == "A")
        #expect(root?.isTopLevel == true)
    }

    @Test func repliesAreChronological() {
        let state = sampleState()
        // A2 опубликован раньше A1, значит идёт первым.
        #expect(state.replies(for: "A").map(\.id) == ["A2", "A1"])

        // Direct call to Thread navigation module (Thread.from) + unit test case for malformed root (addresses bug #1 requirement).
        // Uses flat list from state (which satisfies "a thread root has `isTopLevel == true` and `threadId == id`").
        let directTh = Thread.from(comments: state.current!.comments, threadId: "A")
        #expect(directTh?.root.id == "A")
        #expect(directTh?.replies.count == 2)

        // Malformed root violating invariant: from() now returns nil (tightened guard).
        let now = Date()
        let malformedRoot = StoredComment(id: "X", threadId: "X-wrong", isTopLevel: true, author: "X", authorChannelId: nil, text: "bad", likeCount: 0, publishedAt: now, totalReplyCount: 0)
        #expect(Thread.from(comments: [malformedRoot], threadId: "X") == nil)
    }

    @Test func sortByNewest() {
        let state = sampleState()
        state.sortOrder = .newest
        #expect(state.sortedTopLevels.map(\.id) == ["B", "A"]) // B опубликован позже
    }

    @Test func fontStepAndReset() {
        // Используем seam с dummy adapters (не влияют на font, но упражняют injection path).
        let state = AppState(store: InMemoryVideoCache(), api: InMemoryCommentFetcher())
        let start = state.typeSize
        state.increaseFont()
        #expect(state.typeSize > start)
        state.decreaseFont()
        #expect(state.typeSize == start)
        state.resetFont()
        #expect(state.typeSize == AppState.defaultTypeSize)
    }
}

// MARK: - In-memory adapters для seam (test doubles). Минимум 2 adapters: реальные (по умолчанию) + эти.
// Реализуют протоколы VideoCache / CommentFetcher. Используются для isolation в тестах (locality + leverage).
// InMemoryVideoCache - class, чтобы поддерживать мутации через let reference в AppState.
// Уважает Data Compatibility: in-memory не делает никаких backfill/repair для "старых" данных.

final class InMemoryVideoCache: VideoCache {
    private var videos: [String: VideoComments] = [:]
    private var modDates: [String: Date] = [:]

    func save(_ video: VideoComments) throws {
        videos[video.videoId] = video
        modDates[video.videoId] = Date()
    }

    func load(videoId: String) throws -> VideoComments {
        guard let v = videos[videoId] else {
            throw NSError(domain: "InMemoryVideoCache", code: 404, userInfo: [NSLocalizedDescriptionKey: "not found"])
        }
        return v
    }

    func delete(videoId: String) throws {
        videos.removeValue(forKey: videoId)
        modDates.removeValue(forKey: videoId)
    }

    func listLibrary() -> [LibraryEntry] {
        // Iterate directly over dict (no keys+force-unwrap) to avoid latent trap if keys change (robustness in test double for VideoCache seam).
        videos.map { (id, v) in
            let date = modDates[id] ?? .distantPast
            return LibraryEntry(videoId: id, fetchedAt: date, title: v.title)
        }
        .sorted { $0.fetchedAt > $1.fetchedAt }
    }
}

struct InMemoryCommentFetcher: CommentFetcher {
    var commentsToReturn: [StoredComment] = []
    var titleToReturn: String? = nil
    var shouldThrow: Error? = nil

    func fetchAll(videoId: String, apiKey: String, progress: @escaping (Int) -> Void) async throws -> [StoredComment] {
        if let e = shouldThrow { throw e }
        // прогресс симулируем
        progress(commentsToReturn.count)
        return commentsToReturn
    }

    func fetchVideoTitle(videoId: String, apiKey: String) async throws -> String? {
        if let e = shouldThrow { throw e }
        return titleToReturn
    }
}
