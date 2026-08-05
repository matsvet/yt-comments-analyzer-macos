import Foundation

// DTO-структуры под JSON YouTube Data API v3. Внутренние, только для декодирования.

struct ThreadListResponse: Decodable {
    let items: [ThreadItem]
    let nextPageToken: String?
}

struct ThreadItem: Decodable {
    let snippet: ThreadSnippet
    let replies: Replies?
}

struct ThreadSnippet: Decodable {
    let topLevelComment: CommentResource
    let totalReplyCount: Int
}

struct Replies: Decodable {
    let comments: [CommentResource]
}

struct CommentListResponse: Decodable {
    let items: [CommentResource]
    let nextPageToken: String?
}

struct VideoListResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let snippet: Snippet
        struct Snippet: Decodable {
            let title: String
        }
    }
}

struct CommentResource: Decodable {
    let id: String
    let snippet: CommentSnippet

    func toStored(threadId: String, isTopLevel: Bool, totalReplyCount: Int) -> StoredComment {
        StoredComment(
            id: id,
            threadId: threadId,
            isTopLevel: isTopLevel,
            author: snippet.authorDisplayName,
            authorChannelId: snippet.authorChannelId?.value,
            text: snippet.textDisplay,
            likeCount: snippet.likeCount,
            publishedAt: snippet.publishedAt,
            totalReplyCount: totalReplyCount
        )
    }
}

struct CommentSnippet: Decodable {
    let authorDisplayName: String
    let authorChannelId: ChannelID?
    let textDisplay: String
    let likeCount: Int
    let publishedAt: Date

    struct ChannelID: Decodable {
        let value: String?
    }
}

struct APIErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let code: Int
        let message: String?
        let errors: [Item]?

        struct Item: Decodable {
            let reason: String?
            let message: String?
        }
    }
}
