import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            ResultsListView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        } detail: {
            if state.showSummary {
                SummaryView()
            } else {
                ThreadDetailView()
            }
        }
        .overlay(alignment: .top) {
            if let message = state.errorMessage {
                errorBanner(message)
            }
        }
        .overlay {
            // Кастомные модалки (оверлеи внутри главного окна), чтобы Cmd+Q работал даже когда они открыты.
            // Не используем .sheet, потому что на macOS она создаёт модальную сессию, которая блокирует terminate.
            // Summary теперь показывается нативно в правой колонке detail (вместо модалки), два левых столбца остаются видимыми.
            if state.showSettings {
                CustomModal(isPresented: $state.showSettings) {
                    SettingsView()
                }
            }
        }
        .environment(\.fontScale, state.fontScale)
        .dynamicTypeSize(state.typeSize)
        .background {
            // Доп. хоткей ⌘= для увеличения (без Shift), без лишнего пункта в меню.
            // Поддержка и ⌘= и ⌘+ (с Shift) для удобства.
            Button("") { state.increaseFont() }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Button("") { state.increaseFont() }
                .keyboardShortcut("+", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(state.font(for: .callout))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                state.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .foregroundStyle(.white)
        .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .padding()
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Кастомная "модалка" как оверлей внутри главного окна.
/// Не блокирует Cmd+Q и другие app-level действия, в отличие от .sheet на macOS.
private struct CustomModal<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if isPresented {
                // Затемнение фона
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false
                    }
                    .transition(.opacity)

                // Контент карточкой
                VStack {
                    content()
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 30, y: 10)
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
                .onExitCommand {
                    // Escape закрывает модалку
                    isPresented = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isPresented)
    }
}
