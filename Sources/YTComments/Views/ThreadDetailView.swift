import SwiftUI

/// Правая колонка: корень выбранного треда + все ответы, подсветка найденного.
struct ThreadDetailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Использует углублённый Thread module вместо прямых root/replies + ручного сбора (повышает locality).
        if let threadId = state.selectedThreadId, let th = state.thread(for: threadId) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Родоначальник треда")
                            .font(state.font(for: .headline))

                        CommentRow(
                            comment: th.root,
                            highlighted: state.highlightedCommentId == th.root.id,
                            truncated: false
                        )
                        .id(th.root.id)

                        let replies = th.replies
                        Divider()
                        if replies.isEmpty {
                            Text("Ответов нет")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            Text("Ответы (\(replies.count))")
                                .font(state.font(for: .subheadline))
                                .foregroundStyle(.secondary)
                            ForEach(replies) { reply in
                                CommentRow(
                                    comment: reply,
                                    highlighted: state.highlightedCommentId == reply.id,
                                    truncated: false
                                )
                                .id(reply.id)
                                .padding(.leading, 20)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scrollToHighlight(proxy) }
                .onChange(of: state.highlightedCommentId) { scrollToHighlight(proxy) }
                .onChange(of: state.selectedThreadId) { scrollToHighlight(proxy) }
            }
            .navigationTitle("Тред")
        } else {
            ContentUnavailableView(
                "Тред не выбран",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Выберите комментарий слева, чтобы увидеть весь тред.")
            )
        }
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        let target = state.highlightedCommentId ?? state.selectedThreadId
        guard let target else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target, anchor: .center) }
        }
    }
}
