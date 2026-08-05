import Foundation

/// Кэш комментариев одного видео (то, что сериализуется на диск).
struct VideoComments: Codable {
    let videoId: String
    var title: String?
    let fetchedAt: Date
    var comments: [StoredComment]

    var topLevelCount: Int {
        comments.lazy.filter(\.isTopLevel).count
    }
}
