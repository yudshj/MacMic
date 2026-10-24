import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// NSApp.delegate is SwiftUI's adaptor proxy, so keep a direct reference.
    static private(set) weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

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

        showMainWindow()
    }

    /// The main panel. Owned here (not by a SwiftUI WindowGroup) so closing it only hides it:
    /// a WindowGroup window is deallocated on close and could never be reopened from the menu bar.
    static var mainWindow: NSWindow?
    private var windowCloseObserver: NSObjectProtocol?

    /// Lite mode: when the window closes, throw away its SwiftUI hosting view and the window
    /// itself instead of keeping them resident, so a menu-bar-only app gives the memory back.
    static var isLiteMode: Bool {
        get { UserDefaults.standard.bool(forKey: "macmic_lite_mode") }
        set {
            UserDefaults.standard.set(newValue, forKey: "macmic_lite_mode")
            (NSApp.delegate as? AppDelegate)?.applyLiteMode()
        }
    }

    func applyLiteMode() {
        guard let window = Self.mainWindow, !window.isVisible else { return }
        releaseMainWindow()
    }

    /// Drops the SwiftUI content view and the window so their memory can be reclaimed.
    func releaseMainWindow() {
        guard let window = Self.mainWindow else { return }
        window.contentView = NSView(frame: .zero)
        window.orderOut(nil)
        Self.mainWindow = nil
        Self.returnFreeMemoryToSystem()
    }

    /// Freed heap pages normally stay in the malloc zones. After throwing the UI away, hand them
    /// back so a menu-bar-only app really shrinks its footprint (this is what "light" means here).
    static func returnFreeMemoryToSystem() {
        autoreleasepool {
            // Drain any pending autoreleased view/display-list objects first.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        malloc_zone_pressure_relief(nil, 0)
    }

    @objc func showMainWindow() {
        let window: NSWindow
        if let existing = Self.mainWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: MacMicStyle.windowWidth, height: MacMicStyle.windowHeight),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "MacMic"
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView())
            window.setContentSize(NSSize(width: MacMicStyle.windowWidth, height: MacMicStyle.windowHeight))
            window.center()
            window.setFrameAutosaveName("MacMicMainWindow")
            Self.mainWindow = window

            if Self.isLiteMode {
                windowCloseObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    // Let AppKit finish the close, then release the hosting view.
                    DispatchQueue.main.async { self?.releaseMainWindow() }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar even if window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }
}

// MARK: - Main menu (plain AppKit lifecycle)

extension AppDelegate {
    /// Standard app / Edit / Window menus. Needed because we don't use the SwiftUI App lifecycle:
    /// a SwiftUI `App` only exposes its own scene windows to Accessibility, which hid our
    /// manually-owned main window from VoiceOver and UI scripting.
    static func makeMainMenu() -> NSMenu {
        let l10n = LocalizationManager.shared
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacMic", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: l10n.t("menu_settings"), action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settings.target = AppDelegate.shared
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MacMic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: l10n.t("menu_quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    @objc func openSettings() {
        showMainWindow()
        AppViewModel.shared.showSettings = true
    }
}

@main
enum MacMicMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = AppDelegate.makeMainMenu()
        // Menu-bar-first by default: closing the window releases its UI memory (≈78 MB measured)
        // and reopening costs ~100 ms. Users can turn it off from the menu.
        UserDefaults.standard.register(defaults: ["macmic_lite_mode": true])
        withExtendedLifetime(delegate) { app.run() }
    }
}
