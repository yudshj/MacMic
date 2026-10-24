import AppKit
import SwiftUI
import Combine

public final class MenuBarManager: NSObject, NSMenuDelegate {
    public static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    public weak var viewModel: AppViewModel?

    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var openPanelMenuItem: NSMenuItem!
    private var liteModeMenuItem: NSMenuItem!
    private var settingsMenuItem: NSMenuItem!
    private var quitMenuItem: NSMenuItem!
    private var currentStatusSymbol: String?

    override private init() {
        super.init()
    }

    /// Symbol names for the status item, most specific first. The first one the
    /// running OS provides is used (e.g. `mic.badge.xmark` needs SF Symbols 4 / macOS 13).
    private static func statusSymbolCandidates(for state: ConnectionState) -> [String] {
        switch state {
        case .streaming: return ["mic.fill"]
        case .connecting: return ["mic"]
        case .error: return ["mic.badge.xmark", "exclamationmark.triangle", "mic.slash"]
        case .disconnected: return ["mic.slash"]
        }
    }

    /// Template SF Symbol for the menu bar: macOS tints it for light, dark and tinted
    /// menu bars, so state is conveyed by the glyph rather than by colour.
    public static func makeStatusIcon(for state: ConnectionState, accessibilityDescription: String?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        for name in statusSymbolCandidates(for: state) {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
                .withSymbolConfiguration(config) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    private static func menuSymbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    public func setup(with vm: AppViewModel) {
        self.viewModel = vm

        // Create Status Item in System Menu Bar
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        // Build Menu
        let menu = NSMenu()
        menu.delegate = self

        // 1. Connection Status (Informative, Disabled)
        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // 2. Connect / Disconnect Action
        toggleMenuItem = NSMenuItem(title: "", action: #selector(toggleConnectionClicked), keyEquivalent: "c")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 3. Open Main Panel
        openPanelMenuItem = NSMenuItem(title: "", action: #selector(openPanelClicked), keyEquivalent: "o")
        openPanelMenuItem.target = self
        menu.addItem(openPanelMenuItem)

        // 4. Open Settings
        settingsMenuItem = NSMenuItem(title: "", action: #selector(openSettingsClicked), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        // 5. Lite mode (menu-bar only, releases the UI memory when the window closes)
        liteModeMenuItem = NSMenuItem(title: "", action: #selector(toggleLiteModeClicked), keyEquivalent: "")
        liteModeMenuItem.target = self
        liteModeMenuItem.state = AppDelegate.isLiteMode ? .on : .off
        menu.addItem(liteModeMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Quit
        quitMenuItem = NSMenuItem(title: "", action: #selector(quitClicked), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        item.menu = menu

        updateMenuTitles()

        // Subscribe to ViewModel connection state changes. @Published emits in willSet,
        // so use the emitted value rather than re-reading the view model.
        vm.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateMenuTitles(state: state)
            }
            .store(in: &cancellables)

        // Subscribe to Localization changes
        LocalizationManager.shared.$currentLanguage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuTitles()
            }
            .store(in: &cancellables)
    }

    public func updateMenuTitles(state: ConnectionState? = nil) {
        let l10n = LocalizationManager.shared
        guard let vm = viewModel else { return }

        let state = state ?? vm.connectionState
        let isConn: Bool
        if case .streaming = state { isConn = true } else { isConn = false }

        // 1. Status string
        statusMenuItem.title = isConn ? l10n.t("menu_status_connected") : l10n.t("menu_status_disconnected")

        // 2. Toggle button string
        toggleMenuItem.title = isConn ? l10n.t("menu_action_disconnect") : l10n.t("menu_action_connect")

        // 3. Open Panel
        openPanelMenuItem.title = l10n.t("menu_open_panel")

        // 4. Settings
        settingsMenuItem.title = l10n.t("menu_settings")

        // 5. Quit
        liteModeMenuItem.title = l10n.t("menu_lite_mode")
        liteModeMenuItem.state = AppDelegate.isLiteMode ? .on : .off

        quitMenuItem.title = l10n.t("menu_quit")

        // SF Symbol glyphs for a modern macOS menu look
        toggleMenuItem.image = Self.menuSymbol(isConn ? "stop.fill" : "play.fill")
        openPanelMenuItem.image = Self.menuSymbol("macwindow")
        settingsMenuItem.image = Self.menuSymbol("gearshape")
        quitMenuItem.image = Self.menuSymbol("power")

        // Status item glyph (template image; only rebuilt when the glyph changes).
        if let button = statusItem?.button {
            let symbol = Self.statusSymbolCandidates(for: state).first
            if symbol != currentStatusSymbol || button.image == nil {
                currentStatusSymbol = symbol
                button.image = Self.makeStatusIcon(for: state, accessibilityDescription: "MacMic")
            }
            button.toolTip = vm.statusMessage(using: l10n)
        }
    }

    @objc private func toggleConnectionClicked() {
        viewModel?.toggleConnect()
    }

    @objc public func openPanelClicked() {
        AppDelegate.shared?.showMainWindow()
    }

    @objc private func toggleLiteModeClicked() {
        AppDelegate.isLiteMode.toggle()
        liteModeMenuItem.state = AppDelegate.isLiteMode ? .on : .off
        updateMenuTitles()
    }

    @objc private func openSettingsClicked() {
        openPanelClicked()
        viewModel?.showSettings = true
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
