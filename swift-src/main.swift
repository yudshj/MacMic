import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)

        // Setup Menu Bar Item
        MenuBarManager.shared.setup(with: AppViewModel.shared)

        // Apply Dock Policy if hidden dock is preferred
        let hideDock = UserDefaults.standard.bool(forKey: "macmic_hide_dock")
        if hideDock {
            NSApp.setActivationPolicy(.accessory)
        }

        // Apply saved Theme
        LocalizationManager.shared.applyTheme()

        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.styleMask.remove(.resizable)
                window.isMovableByWindowBackground = true
                window.setContentSize(NSSize(width: MacMicStyle.windowWidth, height: MacMicStyle.windowHeight))
                window.center()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar even if window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MenuBarManager.shared.openPanelClicked()
        }
        return true
    }
}

@main
struct MacMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
