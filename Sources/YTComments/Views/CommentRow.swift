import SwiftUI

/// Одна строка комментария: автор, лайки, текст, метаданные.
struct CommentRow: View {
    let comment: StoredComment
    var highlighted: Bool = false
    var truncated: Bool = true
    /// Подпись-контекст для ответа в результатах поиска, напр. "в треде @Автор".
    var replyContext: String?

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.author)
                    .font(state.font(for: .subheadline))
                    .fontWeight(.semibold)
                if !comment.isTopLevel {
                    Text("ответ")
                        .font(state.font(for: .caption2))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Label("\(comment.likeCount)", systemImage: "hand.thumbsup")
                    .labelStyle(.titleAndIcon)
                    .font(state.font(for: .caption))
                    .foregroundStyle(.secondary)
            }

            if let replyContext {
                Text(replyContext)
                    .font(state.font(for: .caption2))
                    .foregroundStyle(.secondary)
            }

            Text(comment.text)
                .font(state.font(for: .body))
                .lineLimit(truncated ? 3 : nil)
                .fixedSize(horizontal: false, vertical: !truncated)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Text(comment.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(state.font(for: .caption2))
                    .foregroundStyle(.secondary)
                if comment.isTopLevel && comment.totalReplyCount > 0 {
                    Label("\(comment.totalReplyCount)", systemImage: "bubble.left.and.bubble.right")
                        .font(state.font(for: .caption2))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            highlighted ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
