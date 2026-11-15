import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var apiModelInput = ""

    private var isBusy: Bool {
        state.isSummarizing || state.commentChat.isSending || state.isCheckingLLM
            || state.chatGPT.isSigningIn || state.chatGPT.isSigningOut
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(state.font(for: .title2))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Настройки").font(state.font(for: .title2)).bold()
                    Text("Изменения сохраняются автоматически")
                        .font(state.font(for: .caption)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    youtubeSettings
                    connectionSettings
                }
                .padding(20)
            }
            .frame(maxHeight: 440)
            Divider()

            HStack {
                Spacer()
                Button("Готово") { state.showSettings = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .font(state.font(for: .body))
        .frame(width: 480)
        .onAppear { apiModelInput = state.llmModel }
        .task {
            if state.useChatGPT && state.chatGPT.isConnected && state.availableLLMModels.isEmpty {
                await state.fetchAvailableLLMModels()
            }
        }
        .onChange(of: state.chatGPT.isConnected) { _, connected in
            if connected && state.useChatGPT { Task { await state.fetchAvailableLLMModels() } }
        }
    }

    private var connectionSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Подключение", selection: Binding(get: { state.useChatGPT }, set: {
                    state.setChatGPTEnabled($0)
                    if $0 && state.chatGPT.isConnected { Task { await state.fetchAvailableLLMModels() } }
                })) {
                    Text("Подписка ChatGPT").tag(true)
                    Text("API / Ollama").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Подключение ИИ")
                .disabled(isBusy)

                if state.useChatGPT { chatGPTSettings } else { apiSettings }
            }
            .padding(8)
        } label: {
            Label("Саммари и чат", systemImage: "sparkles")
                .font(state.font(for: .headline))
        }
    }

    private var chatGPTSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: state.chatGPT.isConnected ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(state.chatGPT.isConnected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.chatGPT.email ?? "Аккаунт ChatGPT").lineLimit(1).textSelection(.enabled)
                    Text(state.chatGPT.isConnected ? "Подписка подключена" : "Войдите для использования подписки")
                        .font(state.font(for: .caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if state.chatGPT.isSigningIn || state.chatGPT.isSigningOut {
                    ProgressView().controlSize(.small)
                }
                if state.chatGPT.isSigningIn {
                    Button("Отменить") { state.chatGPT.cancelSignIn() }
                } else if state.chatGPT.isConnected {
                    Button("Выйти") {
                        Task {
                            await state.chatGPT.signOut()
                            state.availableLLMModels = []
                            state.llmStatusMessage = ""
                        }
                    }
                    .disabled(isBusy)
                }
            }

            if !state.chatGPT.isConnected {
                Button("Продолжить с ChatGPT") { state.chatGPT.signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
            }
            // Auth errors and consent instructions remain visible without duplicating success copy.
            if !state.chatGPT.message.hasPrefix("ChatGPT подключён.") {
                Text(state.chatGPT.message)
                    .font(state.font(for: .caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.chatGPT.isConnected {
                    Button("Продолжить с ChatGPT") { state.chatGPT.signIn() }.disabled(isBusy)
                }
            }

            Divider()
            HStack {
                if state.availableLLMModels.isEmpty {
                    LabeledContent("Модель", value: state.chatGPTModel.isEmpty ? "Не выбрана" : state.chatGPTModel)
                } else {
                    Picker("Модель", selection: Binding(get: { state.chatGPTModel }, set: { state.setChatGPTModel($0) })) {
                        ForEach(state.availableLLMModels, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(isBusy)
                }
                refreshModelsButton
            }

            Picker("Уровень размышления", selection: Binding(get: { state.chatGPTReasoningEffort }, set: { state.setChatGPTReasoningEffort($0) })) {
                ForEach(ReasoningEffort.allCases) { Text($0.label).tag($0) }
            }
            .disabled(isBusy)
            Text(state.chatGPTReasoningEffort.detail)
                .font(state.font(for: .caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Применяется к саммари и чату. Поддержка уровней зависит от модели.")
                .font(state.font(for: .caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            modelStatus

            Divider()
            Text("Комментарии и вопросы отправляются в OpenAI и расходуют лимиты вашей подписки.")
                .font(state.font(for: .caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Доступ и лимиты в ChatGPT ↗", destination: URL(string: "https://chatgpt.com/#settings")!)
                .font(state.font(for: .caption))
        }
    }

    private var apiSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Адрес API", text: Binding(get: { state.llmBaseURL }, set: {
                state.setLLMConfig(baseURL: $0, apiKey: state.llmAPIKey)
                state.availableLLMModels = []
            }))
            .help("Например: http://localhost:11434/v1 или https://api.groq.com/openai/v1")
            SecureField("API-ключ", text: Binding(get: { state.llmAPIKey }, set: {
                state.setLLMConfig(baseURL: state.llmBaseURL, apiKey: $0)
                state.availableLLMModels = []
            }))
            Text("Для локальной Ollama ключ не требуется.")
                .font(state.font(for: .caption)).foregroundStyle(.secondary)
            HStack {
                if state.availableLLMModels.isEmpty {
                    TextField("Название модели", text: $apiModelInput)
                        .onChange(of: apiModelInput) { _, value in state.setLLMModel(value) }
                } else {
                    Picker("Модель", selection: Binding(get: { state.llmModel }, set: { state.setLLMModel($0) })) {
                        if !state.availableLLMModels.contains(state.llmModel) { Text(state.llmModel).tag(state.llmModel) }
                        ForEach(state.availableLLMModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                refreshModelsButton
            }
            Button("Проверить подключение") { Task { await state.checkLLMStatus() } }
            modelStatus
        }
        .textFieldStyle(.roundedBorder)
        .disabled(isBusy)
    }

    private var refreshModelsButton: some View {
        Button { Task { await state.fetchAvailableLLMModels() } } label: {
            if state.isCheckingLLM { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise") }
        }
        .help("Обновить список моделей")
        .accessibilityLabel("Обновить список моделей")
        .disabled(isBusy || (state.useChatGPT && !state.chatGPT.isConnected))
    }

    @ViewBuilder private var modelStatus: some View {
        if !state.llmStatusMessage.isEmpty && !state.llmStatusMessage.hasPrefix("Нажмите") {
            Text(state.llmStatusMessage)
                .font(state.font(for: .caption))
                .foregroundStyle(state.llmStatusMessage.hasPrefix("✗") ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var youtubeSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Ключ YouTube Data API v3", text: Binding(get: { state.apiKey }, set: { state.setAPIKey($0) }))
                    .textFieldStyle(.roundedBorder)
                Text("Ключ хранится на этом Mac и нужен для загрузки комментариев.")
                    .font(state.font(for: .caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Получить ключ в Google Cloud ↗", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                    .font(state.font(for: .caption))
            }
            .padding(8)
        } label: {
            Label("YouTube", systemImage: "play.rectangle")
                .font(state.font(for: .headline))
        }
    }
}
