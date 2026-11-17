import SwiftUI
import Carbon.HIToolbox

@main
struct VeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(systemName: appDelegate.controller.isLive ? "character.bubble.fill" : "character.bubble")
        }

        Window("언어 팩", id: "languages") {
            LanguageSetupView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = TranslationController()
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌃⌥T
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.controller.toggle()
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }
}

struct MenuContent: View {
    let controller: TranslationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("베일")
        Button(controller.isLive ? "실시간 번역 끄기  ⌃⌥T" : "실시간 번역 켜기  ⌃⌥T") { controller.toggle() }
        Divider()
        Button("언어 팩 관리…") {
            NSApp.activate()
            openWindow(id: "languages")
        }
        Divider()
        Button("종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
