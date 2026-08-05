import SwiftUI

/// Левая колонка: загрузка нового видео, библиотека, доступ к настройкам.
struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Новое видео")
                    .font(state.font(for: .headline))
                TextField("Ссылка на видео или ID", text: $state.videoURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(state.font(for: .body))
                    .onSubmit { Task { await state.fetch() } }
                Button {
                    Task { await state.fetch() }
                } label: {
                    if state.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Загрузка… \(state.loadProgress)")
                                .font(state.font(for: .body))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Загрузить")
                            .font(state.font(for: .body))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isLoading || state.videoURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            Divider()

            List {
                Section("Библиотека") {
                    if state.library.isEmpty {
                        Text("Пока пусто")
                            .font(state.font(for: .callout))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.library) { entry in
                        Button {
                            state.openVideo(entry.videoId)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                let mainTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.videoId
                                Text(mainTitle)
                                    .font(state.font(for: .body))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                // ID как второстепенная информация (меньше, серым), если есть название
                                if let title = entry.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(entry.videoId)
                                        .font(state.font(for: .caption2))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Text(entry.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(state.font(for: .caption))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .help(entry.title ?? entry.videoId)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            state.current?.videoId == entry.videoId
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .contextMenu {
                            Button("Удалить", role: .destructive) {
                                state.deleteVideo(entry.videoId)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                state.showSettings = true
            } label: {
                Label("Настройки", systemImage: "gearshape")
                    .font(state.font(for: .body))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}
