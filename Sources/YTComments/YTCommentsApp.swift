import SwiftUI
import AppKit

@main
struct YTCommentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Пункты добавляются в стандартное меню View.
            CommandGroup(after: .sidebar) {
                Button("Увеличить шрифт") { state.increaseFont() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Уменьшить шрифт") { state.decreaseFont() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Сбросить размер шрифта") { state.resetFont() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// Запуск из терминала через `swift run` поднимает процесс без бандла,
/// поэтому вручную делаем приложение обычным (иконка в Dock, фокус окна).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconUrl) {
            NSApp.applicationIconImage = iconImage
        } else if let iconImage = NSImage(contentsOfFile: "Resources/AppIcon.png") ?? NSImage(contentsOfFile: "Resources/AppIcon.icns") {
            NSApp.applicationIconImage = iconImage
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
