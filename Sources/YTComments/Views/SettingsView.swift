import SwiftUI

/// Ввод и сохранение API-ключа YouTube Data API v3.
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var keyInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки")
                .font(state.font(for: .title2))
                .bold()

            VStack(alignment: .leading, spacing: 6) {
                Text("Ключ YouTube Data API v3")
                    .font(state.font(for: .headline))
                SecureField("AIza…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(state.font(for: .body))
                Text("Ключ хранится локально на этом компьютере. Получить можно в Google Cloud Console -> APIs & Services -> Credentials, включив «YouTube Data API v3».")
                    .font(state.font(for: .caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // LLM: локальная Ollama ИЛИ облачные бесплатные OpenAI-совместимые (Groq, OpenRouter и др.)
            // Мощные модели (70B+) бесплатно с хорошими лимитами. Только для новых данных.
            VStack(alignment: .leading, spacing: 8) {
                Text("LLM для саммари комментариев")
                    .font(state.font(for: .headline))

                TextField("Base URL (локальная: http://localhost:11434/v1  |  Groq: https://api.groq.com/openai/v1 | OpenRouter: https://openrouter.ai/api/v1)", text: $llmBaseURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(state.font(for: .body))

                SecureField("API Key (для Groq/OpenRouter — ваш бесплатный ключ с сайта провайдера)", text: $llmAPIKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(state.font(for: .body))

                HStack(spacing: 8) {
                    Button("Загрузить список моделей") {
                        Task {
                            state.setLLMConfig(baseURL: llmBaseURLInput, apiKey: llmAPIKeyInput)
                            await state.fetchAvailableLLMModels()
                        }
                    }
                    .font(state.font(for: .body))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isCheckingLLM || llmAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if state.isCheckingLLM {
                        ProgressView().controlSize(.small)
                    }
                }

                if !state.availableLLMModels.isEmpty {
                    Picker("Выберите модель из доступных", selection: $llmModelInput) {
                        ForEach(state.availableLLMModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Модель выбрана: \(llmModelInput)")
                        .font(state.font(for: .caption))
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Или введите модель вручную (напр. llama-3.1-70b-versatile)", text: $llmModelInput)
                        .textFieldStyle(.roundedBorder)
                        .font(state.font(for: .body))
                }

                Text("Рекомендую для Groq: llama-3.1-70b-versatile (самая сильная бесплатная) или gemma2-9b-it.\nСначала введи Base URL + API Key, нажми «Загрузить список моделей», затем выбери из Picker.")
                    .font(state.font(for: .caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Проверить статус LLM") {
                        Task {
                            state.setLLMConfig(baseURL: llmBaseURLInput, apiKey: llmAPIKeyInput)
                            state.setLLMModel(llmModelInput)
                            await state.checkLLMStatus()
                        }
                    }
                    .font(state.font(for: .body))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isCheckingLLM)
                }

                Text(state.llmStatusMessage)
                    .font(state.font(for: .caption))
                    .foregroundStyle(state.llmStatusMessage.hasPrefix("✓") ? .green : (state.llmStatusMessage.hasPrefix("✗") ? .red : .secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена") { state.showSettings = false }
                    .font(state.font(for: .body))
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    state.setAPIKey(keyInput)
                    state.setLLMModel(llmModelInput)
                    state.setLLMConfig(baseURL: llmBaseURLInput, apiKey: llmAPIKeyInput)
                    state.showSettings = false
                }
                .font(state.font(for: .body))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            keyInput = state.apiKey
            llmModelInput = state.llmModel
            llmBaseURLInput = state.llmBaseURL
            llmAPIKeyInput = state.llmAPIKey
        }
    }

    // Локальные draft-поля (сохраняются только по кнопке Сохранить)
    @State private var llmModelInput: String = ""
    @State private var llmBaseURLInput: String = ""
    @State private var llmAPIKeyInput: String = ""
}
