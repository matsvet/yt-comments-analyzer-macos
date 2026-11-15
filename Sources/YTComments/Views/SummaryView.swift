import SwiftUI
import AppKit

/// Саммари и диалог по комментариям выбранного видео в правой колонке.
struct SummaryView: View {
    @Environment(AppState.self) private var state
    @State private var summaryExpanded = true

    var body: some View {
        @Bindable var chat = state.commentChat
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Саммари и обсуждение")
                        .font(state.font(for: .title3)).bold()
                    Spacer()
                    Button { state.showSummary = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Закрыть панель (Esc)")
                }
                Text("По комментариям выбранного видео. Само видео и расшифровка не загружены.")
                    .font(state.font(for: .caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            summarySection
                            Divider()
                            HStack {
                                Text("Обсудить комментарии").font(state.font(for: .headline))
                                Spacer()
                                Button("Очистить диалог") { chat.clear() }
                                    .font(state.font(for: .caption))
                                    .disabled(chat.turns.isEmpty)
                            }
                            if chat.turns.isEmpty {
                                Text("Например: «В чём расходятся мнения?», «Кто приводит конкретные примеры?», «Подробнее о критике».")
                                    .font(state.font(for: .callout)).foregroundStyle(.secondary)
                            }
                            ForEach(chat.turns) { turn in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Вы").font(state.font(for: .caption)).foregroundStyle(.secondary)
                                    Text(turn.question)
                                        .font(state.font(for: .body)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                    if let answer = turn.answer {
                                        Text(answer).font(state.font(for: .body)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !turn.sources.isEmpty {
                                            DisclosureGroup("Источники (\(turn.sources.count))") {
                                                VStack(alignment: .leading, spacing: 12) {
                                                    ForEach(Array(turn.sources.enumerated()), id: \.element.id) { index, source in
                                                        VStack(alignment: .leading, spacing: 4) {
                                                            Button("[\(turn.sourceNumbers[index])] \(source.author)") {
                                                                state.selectThread(source.threadId, highlight: source.id)
                                                            }
                                                            .buttonStyle(.borderless)
                                                            .help("Открыть исходный комментарий в треде")
                                                            Text(turn.sourceQuotes.indices.contains(index) ? turn.sourceQuotes[index] : String(source.text.prefix(500)))
                                                                .font(state.font(for: .caption)).textSelection(.enabled)
                                                        }
                                                    }
                                                }.padding(.top, 6)
                                            }
                                            .font(state.font(for: .caption))
                                        }
                                        Text(turn.completeAnalysis
                                             ? "Полный проход: \(turn.analyzedComments) загруженных комментариев."
                                             : "Локальный поиск: \(turn.scannedComments). Модель прочитала фрагменты \(turn.analyzedComments) комментариев; финальная подборка: \(turn.searchedComments).")
                                            .font(state.font(for: .caption)).foregroundStyle(.secondary)
                                    } else if let error = turn.error {
                                        Text(error).font(state.font(for: .callout)).foregroundStyle(.red)
                                        if turn.id == chat.turns.last?.id {
                                            Button("Повторить вопрос") {
                                                chat.prepareRetry()
                                                state.askAboutComments()
                                            }
                                            .disabled(chat.isSending || state.isSummarizing)
                                        }
                                    } else {
                                        HStack {
                                            ProgressView().controlSize(.small)
                                            Text(chat.statusMessage).font(state.font(for: .callout))
                                        }
                                    }
                                }
                                Divider()
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: chat.turns.count) { _, count in
                        if count > 0 { summaryExpanded = false }
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                    .onChange(of: chat.turns.last?.answer) { _, _ in
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                    .onAppear {
                        if !chat.turns.isEmpty {
                            summaryExpanded = false
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .layoutPriority(-1)

                Divider()
                Toggle("Все комментарии", isOn: $chat.fullScan)
                    .font(state.font(for: .caption))
                    .help("Принудительный полный проход вместо поиска по подборке. Потребует больше запросов к модели.")
                    .disabled(chat.isSending || state.isSummarizing)
                TextField("Спросите по комментариям…", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(state.font(for: .body))
                    .lineLimit(1...4)
                    .onSubmit { send() }
                HStack {
                    if chat.draft.count > 1500 {
                        Text("Вопрос до 1500 символов")
                            .font(state.font(for: .caption)).foregroundStyle(.red)
                    }
                    Spacer()
                    if chat.isSending {
                        Button("Остановить") { chat.cancel() }
                    } else {
                        Button("Отправить") { send() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canSend)
                    }
                }
                .font(state.font(for: .body))
            }
            .padding()
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onExitCommand { state.showSummary = false }
    }

    private var canSend: Bool {
        !state.isSummarizing && !state.commentChat.isSending
            && !(state.current?.comments.isEmpty ?? true)
            && !state.commentChat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.commentChat.draft.count <= 1500
    }

    private func send() {
        guard canSend else { return }
        state.askAboutComments()
    }

    private var summarySection: some View {
        DisclosureGroup("Саммари", isExpanded: $summaryExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let text = state.summary, !text.isEmpty {
                    Text(text).font(state.font(for: .body)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let coverage = state.summaryCoverage {
                        Text(coverage).font(state.font(for: .caption)).foregroundStyle(.secondary)
                    }
                    if !state.summarySources.isEmpty {
                        DisclosureGroup("Источники саммари") {
                            ForEach(Array(state.summarySources.enumerated()), id: \.offset) { _, source in
                                VStack(alignment: .leading, spacing: 4) {
                                    Button("[\(source.number)] \(source.comment.author)") {
                                        state.selectThread(source.comment.threadId, highlight: source.comment.id)
                                    }
                                    .buttonStyle(.borderless)
                                    Text(source.quote).textSelection(.enabled)
                                }.padding(.vertical, 4)
                            }
                        }.font(state.font(for: .caption))
                    }
                    HStack {
                        Button("Пересобрать саммари") { Task { await state.summarizeCurrentVideo(regenerate: true) } }
                            .disabled(state.isSummarizing || state.commentChat.isSending)
                        Spacer()
                        Button("Скопировать") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                    .font(state.font(for: .caption))
                } else if !state.isSummarizing {
                    Button("Сгенерировать саммари") { Task { await state.summarizeCurrentVideo() } }
                        .disabled(state.current == nil || state.commentChat.isSending)
                }
                if state.isSummarizing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(state.summaryProgress).font(state.font(for: .callout))
                        Button("Остановить") { state.cancelSummary() }
                    }
                }
            }.padding(.top, 8)
        }
        .font(state.font(for: .headline))
    }
}
