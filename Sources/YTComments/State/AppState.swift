import Foundation
import Observation
import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case likes
    case newest
    case oldest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .likes:  return "По лайкам"
        case .newest: return "Сначала новые"
        case .oldest: return "Сначала старые"
        }
    }
}

@Observable
@MainActor
final class AppState {
    private static let apiKeyKey = "YTCommentsAPIKey"
    private static let llmModelKey = "YTCommentsLLMModel"
    private static let llmBaseURLKey = "YTCommentsLLMBaseURL"
    private static let llmAPIKeyKey = "YTCommentsLLMAPIKey"
    static let defaultLLMModel = "llama3.1:8b"
    static let defaultLLMBaseURL = "http://localhost:11434/v1"  // Ollama OpenAI-compat; для Groq: https://api.groq.com/openai/v1
    static let defaultLLMAPIKey = "ollama"  // для локальной часто "ollama", для Groq — ваш ключ

    // Compat для тестов (typeSize moved to FontScale child).
    static let defaultTypeSize = FontScale.defaultTypeSize

    // Ввод / настройки
    var apiKey: String
    var videoURLInput: String = ""
    var sortOrder: SortOrder = .likes

    // Поисковые флаги делегируются child SearchState (см. ниже). Для @Bindable совместимости.

    // Загрузка
    var isLoading: Bool = false
    var loadProgress: Int = 0
    var errorMessage: String?

    // Данные
    var current: VideoComments? {
        didSet {
            if oldValue != current {
                cancelSummary()
                if oldValue?.videoId == current?.videoId { commentChat.forgetVideo(oldValue?.videoId ?? "") }
                commentChat.selectVideo(current?.videoId)
                summary = nil
                summaryCoverage = nil
                summarySources = []
            }
        }
    }
    let commentChat = CommentChatState()
    var library: [LibraryEntry] = []

    // Навигация по тредам
    var selectedThreadId: String?
    var highlightedCommentId: String?

    // Модальные окна и панели делегируются child SheetState (см. ниже, для split монолита).
    // LLM: локальная Ollama или облачная OpenAI-совместимая (Groq и др. бесплатные мощные модели)
    // Только для *новых* данных (см. правила проекта).
    let chatGPT = ChatGPTSession()
    var useChatGPT = UserDefaults.standard.object(forKey: "UseChatGPTSubscription") as? Bool ?? true
    var chatGPTModel = UserDefaults.standard.string(forKey: "ChatGPTModel") ?? ""
    var chatGPTReasoningEffort = ReasoningEffort(rawValue: UserDefaults.standard.string(forKey: "ChatGPTReasoningEffort") ?? "") ?? .medium
    var activeLLMModel: String { useChatGPT ? chatGPTModel : llmModel }
    var llmModel: String
    var llmBaseURL: String
    var llmAPIKey: String
    var summary: String?
    var isSummarizing: Bool = false
    var summaryProgress = ""
    var summaryCoverage: String?
    var summarySources: [(number: Int, comment: StoredComment, quote: String)] = []
    let commentAnalysis = CommentAnalysis()
    private var summaryTask: Task<Void, Never>?
    private var summaryRun = UUID()
    private var configurationRevision = UUID()
    private var analysisConfiguration: String {
        "\(configurationRevision)|\(activeLLMModel)|\(chatGPTReasoningEffort.rawValue)|\(chatGPT.cacheIdentity)"
    }

    // Статус LLM для UI (проверяется вручную в настройках)
    var llmStatusMessage: String = "Нажмите «Проверить статус LLM» в настройках, чтобы узнать статус."
    var isCheckingLLM: Bool = false

    var availableLLMModels: [String] = []


    // Дети (child @Observable) для разбивки монолита. AppState — тонкий оркестратор.
    // Font вынесен полностью (изолированный модуль, низкий риск).
    let font = FontScale()

    // Search flags вынесены в child (углубление search). Forwarding для минимальной breakage.
    let searchState = SearchState()
    let sheets = SheetState()  // для showSettings/showSummary (UI routing, часть монолита)

    // Forwarding для search флагов (чтобы старый код и @Bindable в ResultsListView продолжали работать без правок).
    // Позже можно перевести View на прямой bind к state.searchState .
    var searchText: String {
        get { searchState.searchText }
        set { searchState.searchText = newValue }
    }
    var matchCase: Bool {
        get { searchState.matchCase }
        set { searchState.matchCase = newValue }
    }
    var wholeWord: Bool {
        get { searchState.wholeWord }
        set { searchState.wholeWord = newValue }
    }
    var searchAuthors: Bool {
        get { searchState.searchAuthors }
        set { searchState.searchAuthors = newValue }
    }

    // Forwarding для sheets (минимально).
    var showSettings: Bool {
        get { sheets.showSettings }
        set { sheets.showSettings = newValue }
    }
    var showSummary: Bool {
        get { sheets.showSummary }
        set { sheets.showSummary = newValue }
    }

    // Seam: store и api теперь инъектируемы (по умолчанию реальные adapters).
    // Это создаёт настоящий seam: минимум 2 adapters (CommentStore/YouTubeAPI + in-memory тестовые).
    // Улучшает: locality (оркестрация не смешана с impl), leverage (тесты без FS/сети), deletion test.
    private let store: any VideoCache
    private let api: any CommentFetcher
    private var llmClient = LLMClient()

    // Init с дефолтами: существующий AppState() (и эквиваленты в entry point приложения) продолжают работать (реальные adapters).
    init(
        store: any VideoCache = CommentStore(),
        api: any CommentFetcher = YouTubeAPI()
    ) {
        self.store = store
        self.api = api
        apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        llmModel = UserDefaults.standard.string(forKey: Self.llmModelKey) ?? Self.defaultLLMModel
        llmBaseURL = UserDefaults.standard.string(forKey: Self.llmBaseURLKey) ?? Self.defaultLLMBaseURL
        llmAPIKey = UserDefaults.standard.string(forKey: Self.llmAPIKeyKey) ?? Self.defaultLLMAPIKey
        library = self.store.listLibrary()
        updateLLMClientConfig()
    }

    // MARK: - Масштаб шрифта (делегирует child FontScale для глубины/локальности)
    // Раньше было в монолите; теперь отдельный модуль (см. FontScale.swift). AppState фасад.

    var typeSize: DynamicTypeSize { font.typeSize }

    func increaseFont() { font.increase() }
    func decreaseFont() { font.decrease() }

    func resetFont() { font.reset() }

    var fontScale: CGFloat { font.scale }

    /// Делегирует углублённому FontScale (базовые размеры из NSFont.preferredFont).
    func font(for style: Font.TextStyle) -> Font {
        font.font(for: style)
    }

    // MARK: - Настройки

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.apiKeyKey)
    }

    func setLLMModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = trimmed.isEmpty ? Self.defaultLLMModel : trimmed
        guard llmModel != selected else { return }
        configurationRevision = UUID()
        llmModel = selected
        UserDefaults.standard.set(llmModel, forKey: Self.llmModelKey)
        llmStatusMessage = "Модель изменена. Проверьте статус в настройках."
        updateLLMClientConfig()
    }

    func setLLMConfig(baseURL: String, apiKey: String) {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard llmBaseURL != endpoint || llmAPIKey != key else { return }
        configurationRevision = UUID()
        llmBaseURL = endpoint
        llmAPIKey = key
        UserDefaults.standard.set(llmBaseURL, forKey: Self.llmBaseURLKey)
        UserDefaults.standard.set(llmAPIKey, forKey: Self.llmAPIKeyKey)
        updateLLMClientConfig()
        llmStatusMessage = "Конфигурация LLM обновлена. Проверьте статус."
    }

    func setChatGPTEnabled(_ enabled: Bool) {
        guard enabled != useChatGPT else { return }
        configurationRevision = UUID()
        commentChat.cancel()
        useChatGPT = enabled
        UserDefaults.standard.set(enabled, forKey: "UseChatGPTSubscription")
        availableLLMModels = []
        llmStatusMessage = ""
        updateLLMClientConfig()
    }

    func setChatGPTModel(_ model: String) {
        guard model != chatGPTModel else { return }
        configurationRevision = UUID()
        chatGPTModel = model
        UserDefaults.standard.set(model, forKey: "ChatGPTModel")
    }

    func setChatGPTReasoningEffort(_ effort: ReasoningEffort) {
        guard effort != chatGPTReasoningEffort else { return }
        configurationRevision = UUID()
        chatGPTReasoningEffort = effort
        UserDefaults.standard.set(effort.rawValue, forKey: "ChatGPTReasoningEffort")
        updateLLMClientConfig()
    }

    private func updateLLMClientConfig() {
        llmClient.reasoningEffort = chatGPTReasoningEffort
        llmClient.chatGPT = useChatGPT ? chatGPT : nil
        // Safe construction without force-unwrap (bug fix): fallback to default only if custom base produces invalid URL string.
        // Default is compile-time known valid; explicit fatal only for impossible broken constant (clearer than ! trap).
        let endpointStr = llmBaseURL.hasSuffix("/chat/completions") ? llmBaseURL : llmBaseURL.trimmingCharacters(in: ["/"]) + "/chat/completions"
        if let u = URL(string: endpointStr) {
            llmClient.chatEndpoint = u
        } else if let d = URL(string: Self.defaultLLMBaseURL + "/chat/completions") {
            llmClient.chatEndpoint = d
        } else {
            fatalError("Невалидный defaultLLMBaseURL в AppState (LLM seam); никогда не должно случаться.")
        }
        llmClient.apiKey = llmAPIKey.isEmpty ? "ollama" : llmAPIKey
    }

    // MARK: - Загрузка

    func fetch() async {
        errorMessage = nil
        guard let videoId = VideoIDParser.extract(from: videoURLInput) else {
            errorMessage = YouTubeError.invalidURL.errorDescription
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = YouTubeError.missingAPIKey.errorDescription
            return
        }

        isLoading = true
        loadProgress = 0
        defer { isLoading = false }

        do {
            let comments = try await api.fetchAll(videoId: videoId, apiKey: apiKey) { count in
                Task { @MainActor in self.loadProgress = count }
            }
            let title = (try? await api.fetchVideoTitle(videoId: videoId, apiKey: apiKey)) ?? nil
            let video = VideoComments(videoId: videoId, title: title, fetchedAt: Date(), comments: comments)
            try store.save(video)
            current = video
            summary = nil
            searchText = ""
            selectedThreadId = nil
            highlightedCommentId = nil
            refreshLibrary()
        } catch let error as YouTubeError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Библиотека

    func refreshLibrary() {
        library = store.listLibrary()
    }

    func openVideo(_ videoId: String) {
        do {
            let loaded = try store.load(videoId: videoId)
            current = loaded
            summary = nil
            videoURLInput = videoId
            searchText = ""
            selectedThreadId = nil
            highlightedCommentId = nil
            errorMessage = nil
            // NOTE: No backfilling/migration of titles (or any other fields) for old caches.
            // Per project rules: all changes apply only to newly saved data during development.
        } catch {
            errorMessage = "Не удалось открыть кэш видео: \(error.localizedDescription)"
        }
    }

    func deleteVideo(_ videoId: String) {
        commentChat.forgetVideo(videoId)
        try? store.delete(videoId: videoId)
        if current?.videoId == videoId {
            current = nil
            summary = nil
            selectedThreadId = nil
            highlightedCommentId = nil
        }
        refreshLibrary()
    }

    // MARK: - Треды и поиск

    var isSearching: Bool { searchState.isSearching }

    /// Корни тредов, отсортированные по текущему порядку.
    /// Делегирует углублённому search module (topLevelComments).
    var sortedTopLevels: [StoredComment] {
        guard let current else { return [] }
        let tops = topLevelComments(in: current.comments)
        return sorted(tops)
    }

    /// Результаты поиска: пустой запрос -> корни тредов; иначе все совпадения (корни И ответы).
    /// Учитывает тумблеры регистра, целого слова и поиска по авторам.
    /// Делегирует углублённому Offline Search module (pure search func + SearchConfig).
    var searchResults: [StoredComment] {
        guard let current else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let base = search(comments: current.comments, config: searchState.config, query: query)
        return sorted(base)
    }

    /// Возвращает собранный Thread (глубокий модуль). Используется для Thread navigation.
    func thread(for threadId: String) -> Thread? {
        guard let current else { return nil }
        return Thread.from(comments: current.comments, threadId: threadId)
    }

    /// Корневой комментарий треда. Делегирует углублённому Thread module (чтобы не дублировать flat logic).
    func root(for threadId: String) -> StoredComment? {
        thread(for: threadId)?.root
    }

    /// Ответы треда в хронологическом порядке. Делегирует углублённому Thread module.
    func replies(for threadId: String) -> [StoredComment] {
        thread(for: threadId)?.replies ?? []
    }

    func selectThread(_ threadId: String, highlight commentId: String?) {
        selectedThreadId = threadId
        highlightedCommentId = commentId
        showSummary = false  // при выборе треда/комментария из списка всегда показываем тред в правой панели (вместо саммари)
    }

    private func sorted(_ comments: [StoredComment]) -> [StoredComment] {
        switch sortOrder {
        case .likes:
            return comments.sorted { ($0.likeCount, $0.publishedAt) > ($1.likeCount, $1.publishedAt) }
        case .newest:
            return comments.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:
            return comments.sorted { $0.publishedAt < $1.publishedAt }
        }
    }

    // MARK: - Экспорт

    /// Форматирует все комментарии текущего видео в plain text (для сохранения как .txt).
    /// Порядок: топ-уровневые как пришли из API (обычно по времени), ответы внутри треда по времени.
    func commentsAsTxt() -> String? {
        guard let current else { return nil }

        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        let title = current.title ?? current.videoId
        lines.append("Комментарии YouTube")
        lines.append("Видео: \(title)")
        lines.append("ID: \(current.videoId)")
        lines.append("Ссылка: https://www.youtube.com/watch?v=\(current.videoId)")
        lines.append("Загружено: \(df.string(from: current.fetchedAt))")

        let total = current.comments.count
        let topCount = current.comments.filter(\.isTopLevel).count
        lines.append("Всего комментариев: \(total) (корневых тредов: \(topCount))")
        lines.append(String(repeating: "-", count: 60))
        lines.append("")

        let topLevels = current.comments.filter { $0.isTopLevel }

        for top in topLevels {
            lines.append(contentsOf: formattedCommentLines(top, df: df, indent: ""))
            let replies = self.replies(for: top.id)
            for reply in replies {
                lines.append(contentsOf: formattedCommentLines(reply, df: df, indent: "    "))
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formattedCommentLines(_ comment: StoredComment, df: DateFormatter, indent: String) -> [String] {
        let likesPart = comment.likeCount > 0 ? " [+\(comment.likeCount)]" : ""
        let header = "\(indent)\(comment.author)\(likesPart) (\(df.string(from: comment.publishedAt))):"
        let textIndent = indent + "    "
        let textLines = comment.text
            .components(separatedBy: .newlines)
            .map { line in textIndent + line }
        return [header] + textLines
    }

    /// Предлагаемое имя файла при экспорте в .txt (по умолчанию в Downloads).
    /// Использует краткое название видео (если есть), а не ID.
    func suggestedTxtFilename() -> String {
        guard let current else { return "комментарии.txt" }

        let raw = current.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? current.videoId
        let sanitized = sanitizeForFilename(raw)

        let suffix = " - комментарии.txt"
        let maxLen = 80
        let truncated: String
        if sanitized.count > maxLen {
            truncated = String(sanitized.prefix(maxLen - 3)) + "..."
        } else {
            truncated = sanitized
        }

        return "\(truncated)\(suffix)"
    }

    private func sanitizeForFilename(_ string: String) -> String {
        // Убираем символы, недопустимые в именах файлов
        let unsafe = CharacterSet(charactersIn: "\\/:*?\"<>|")
        var result = string.components(separatedBy: unsafe).joined(separator: " ")

        // Схлопываем лишние пробелы
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? "video" : result
    }

    // MARK: - Анализ комментариев по явному запросу

    func cancelSummary() {
        summaryRun = UUID()
        summaryTask?.cancel()
        summaryTask = nil
        isSummarizing = false
        summaryProgress = ""
    }

    func summarizeCurrentVideo(regenerate: Bool = false) async {
        guard let video = current, !isSummarizing, !commentChat.isSending else { return }
        updateLLMClientConfig()
        let run = UUID()
        summaryRun = run
        isSummarizing = true
        errorMessage = nil
        summaryProgress = "Подготавливаю полный анализ…"
        let client = llmClient, model = activeLLMModel, configuration = analysisConfiguration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.summaryRun == run { self.isSummarizing = false; self.summaryTask = nil }
            }
            do {
                let result = try await self.commentAnalysis.summarize(video: video, client: client, model: model,
                                                                      configuration: configuration, regenerate: regenerate) { [weak self] status in
                    if self?.summaryRun == run { self?.summaryProgress = status }
                }
                try Task.checkCancellation()
                guard self.summaryRun == run, self.current == video else { return }
                self.summary = result.text
                self.summaryCoverage = "Полный проход: \(result.total) загруженных комментариев, порций: \(result.portions). Выводы проверены по цитатам."
                let sourceComments = CommentCorpus.sourceComments(in: video)
                self.summarySources = result.evidence.compactMap { evidence in
                    guard sourceComments.indices.contains(evidence.source - 1) else { return nil }
                    return (evidence.source, sourceComments[evidence.source - 1], evidence.quote)
                }
            } catch {
                guard !Task.isCancelled, self.summaryRun == run else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        summaryTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func askAboutComments() {
        guard let video = current, !isSummarizing else { return }
        updateLLMClientConfig()
        commentChat.send(video: video, summary: summary, client: llmClient, model: activeLLMModel,
                         analysis: commentAnalysis, configuration: analysisConfiguration)
    }

    /// Проверяет статус LLM (локальной или облачной) и модели. Обновляет llmStatusMessage.
    func checkLLMStatus() async {
        isCheckingLLM = true
        defer { isCheckingLLM = false }
        updateLLMClientConfig()

        do {
            let models = try await llmClient.listModels()
            availableLLMModels = useChatGPT ? models : models.sorted()
            if useChatGPT && !models.contains(chatGPTModel), let first = models.first { setChatGPTModel(first) }

            let modelLower = activeLLMModel.lowercased()
            let hasModel = models.contains { $0.lowercased() == modelLower }
            if hasModel {
                llmStatusMessage = "✓ Готово: модель '\(activeLLMModel)' доступна через настроенный endpoint."
            } else {
                llmStatusMessage = "⚠ Endpoint отвечает, но модель '\(activeLLMModel)' не найдена среди доступных. Выберите модель из списка ниже после нажатия «Загрузить список моделей»."
            }
        } catch {
            availableLLMModels = []
            llmStatusMessage = "✗ " + error.localizedDescription
        }
    }

    func fetchAvailableLLMModels() async {
        isCheckingLLM = true
        defer { isCheckingLLM = false }
        updateLLMClientConfig()

        do {
            let models = try await llmClient.listModels()
            availableLLMModels = useChatGPT ? models : models.sorted()
            if useChatGPT && !models.contains(chatGPTModel), let first = models.first { setChatGPTModel(first) }
            llmStatusMessage = "Загружено \(availableLLMModels.count) моделей. Выберите из списка."
        } catch {
            availableLLMModels = []
            llmStatusMessage = "✗ " + error.localizedDescription
        }
    }
}
