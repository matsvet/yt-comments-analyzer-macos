import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

/// Средняя колонка: заголовок видео, поиск, тумблеры, сортировка и список результатов.
/// Пустой запрос -> корни тредов; иначе -> совпадения (корни И ответы).
struct ResultsListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        @Bindable var search = state.searchState  // bind к child SearchState (после split монолита)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let current = state.current {
                    titleLink(for: current)
                }

                HStack(spacing: 6) {
                    TextField("Поиск по тексту комментариев", text: $search.searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(state.font(for: .body))

                    Toggle("Aa", isOn: $search.matchCase)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Учитывать регистр")

                    Toggle("Слово", isOn: $search.wholeWord)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Слово целиком")

                    Toggle("Автор", isOn: $search.searchAuthors)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Искать также в именах авторов")
                }

                HStack {
                    ZStack(alignment: .leading) {
                        // Hidden labels to force the picker container to be wide enough
                        // for the longest option from the very first render.
                        ForEach(SortOrder.allCases) { order in
                            Text(order.label)
                                .font(state.font(for: .body))
                                .hidden()
                                .padding(.trailing, 18) // reserve space for the dropdown chevron
                        }

                        Picker("Сортировка", selection: $state.sortOrder) {
                            ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Spacer()
                    Text(countLabel)
                        .font(state.font(for: .caption))
                        .foregroundStyle(.secondary)
                    if state.current != nil {
                        Button {
                            exportAsTxt()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Скачать все комментарии как .txt")
                        .padding(.leading, 6)

                        Button {
                            guard state.current != nil else { return }
                            if state.showSummary {
                                state.showSummary = false
                            } else {
                                if state.summary == nil {
                                    Task { await state.summarizeCurrentVideo() }
                                }
                                state.showSummary = true
                            }
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(state.showSummary ? Color.accentColor : .secondary)
                        .help("Саммари и диалог по комментариям в правой панели")
                        .padding(.leading, 6)
                        .disabled(state.isSummarizing)
                    }
                }
            }
            .padding()

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func titleLink(for video: VideoComments) -> some View {
        Link(destination: URL(string: "https://www.youtube.com/watch?v=\(video.videoId)")!) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(video.title ?? video.videoId)
                    .font(state.font(for: .title3))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.small)
            }
            .foregroundStyle(.link)
        }
        .help("Открыть видео на YouTube")
    }

    @ViewBuilder
    private var content: some View {
        if state.current == nil {
            ContentUnavailableView(
                "Нет данных",
                systemImage: "text.bubble",
                description: Text("Загрузите видео в боковой панели.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.searchResults.isEmpty {
            ContentUnavailableView(
                "Ничего не найдено",
                systemImage: "magnifyingglass",
                description: Text("Попробуйте другой запрос.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(state.searchResults) { comment in
                    CommentRow(
                        comment: comment,
                        highlighted: isActive(comment),
                        replyContext: replyContext(for: comment)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selectThread(
                            comment.threadId,
                            highlight: comment.isTopLevel ? nil : comment.id
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                }
            }
            .listStyle(.inset)
        }
    }

    private var countLabel: String {
        guard state.current != nil else { return "" }
        return state.isSearching
            ? "Найдено: \(state.searchResults.count)"
            : "Тредов: \(state.sortedTopLevels.count)"
    }

    private func replyContext(for comment: StoredComment) -> String? {
        guard !comment.isTopLevel else { return nil }
        // Использует Thread module (через thread(for:)) для получения root, вместо прямого root(for:) на AppState.
        if let th = state.thread(for: comment.threadId) {
            return "в треде \(th.root.author)"
        }
        return "ответ в треде"
    }

    private func isActive(_ comment: StoredComment) -> Bool {
        if comment.isTopLevel {
            return state.selectedThreadId == comment.id && state.highlightedCommentId == nil
        }
        return state.highlightedCommentId == comment.id
    }

    private func exportAsTxt() {
        guard let text = state.commentsAsTxt() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = state.suggestedTxtFilename()
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }
        panel.canCreateDirectories = true
        panel.title = "Сохранить комментарии"
        panel.prompt = "Сохранить"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                state.errorMessage = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }
}
