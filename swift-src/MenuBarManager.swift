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
    private var settingsMenuItem: NSMenuItem!
    private var quitMenuItem: NSMenuItem!

    override private init() {
        super.init()
    }

    public static func makeMacMicIcon(connected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let color: NSColor
            if connected {
                color = NSColor(srgbRed: 0.20, green: 0.82, blue: 0.38, alpha: 1.0)
            } else {
                color = NSColor.black
            }

            color.setFill()
            color.setStroke()

            // 1. Mic Capsule
            let capsuleRect = NSRect(x: 6.9, y: 7.0, width: 4.2, height: 7.5)
            let capsule = NSBezierPath(roundedRect: capsuleRect, xRadius: 2.1, yRadius: 2.1)
            capsule.fill()

            // 2. Mic Stand Arc
            let standArc = NSBezierPath()
            standArc.lineWidth = 1.35
            standArc.lineCapStyle = .round
            standArc.appendArc(withCenter: NSPoint(x: 9.0, y: 9.8), radius: 3.6, startAngle: 180, endAngle: 0, clockwise: true)
            standArc.stroke()

            // 3. Pole & Base
            let pole = NSBezierPath()
            pole.lineWidth = 1.35
            pole.lineCapStyle = .round
            pole.move(to: NSPoint(x: 9.0, y: 6.2))
            pole.line(to: NSPoint(x: 9.0, y: 3.0))
            pole.move(to: NSPoint(x: 6.0, y: 3.0))
            pole.line(to: NSPoint(x: 12.0, y: 3.0))
            pole.stroke()

            // 4. Outer Sound Waves (distinctive to MacMic AppIcon)
            let waveLeft = NSBezierPath()
            waveLeft.lineWidth = 1.35
            waveLeft.lineCapStyle = .round
            waveLeft.appendArc(withCenter: NSPoint(x: 9.0, y: 10.3), radius: 6.2, startAngle: 135, endAngle: 225, clockwise: false)
            waveLeft.stroke()

            let waveRight = NSBezierPath()
            waveRight.lineWidth = 1.35
            waveRight.lineCapStyle = .round
            waveRight.appendArc(withCenter: NSPoint(x: 9.0, y: 10.3), radius: 6.2, startAngle: -45, endAngle: 45, clockwise: false)
            waveRight.stroke()

            return true
        }

        img.isTemplate = !connected
        return img
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
        if let button = item.button {
            button.image = Self.makeMacMicIcon(connected: false)
        }
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

        menu.addItem(NSMenuItem.separator())

        // 5. Quit
        quitMenuItem = NSMenuItem(title: "", action: #selector(quitClicked), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        item.menu = menu

        updateMenuTitles()

        // Subscribe to ViewModel connection state changes
        vm.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuTitles()
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

    public func updateMenuTitles() {
        let l10n = LocalizationManager.shared
        guard let vm = viewModel else { return }

        let isConn = vm.isStreaming

        // 1. Status string
        statusMenuItem.title = isConn ? l10n.t("menu_status_connected") : l10n.t("menu_status_disconnected")

        // 2. Toggle button string
        toggleMenuItem.title = isConn ? l10n.t("menu_action_disconnect") : l10n.t("menu_action_connect")

        // 3. Open Panel
        openPanelMenuItem.title = l10n.t("menu_open_panel")

        // 4. Settings
        settingsMenuItem.title = l10n.t("menu_settings")

        // 5. Quit
        quitMenuItem.title = l10n.t("menu_quit")

        // SF Symbol glyphs for a modern macOS menu look
        toggleMenuItem.image = Self.menuSymbol(isConn ? "stop.fill" : "play.fill")
        openPanelMenuItem.image = Self.menuSymbol("macwindow")
        settingsMenuItem.image = Self.menuSymbol("gearshape")
        quitMenuItem.image = Self.menuSymbol("power")

        // Update status icon with custom MacMic AppIcon representation
        if let button = statusItem?.button {
            button.image = Self.makeMacMicIcon(connected: isConn)
        }
    }

    @objc private func toggleConnectionClicked() {
        viewModel?.toggleConnect()
    }

    @objc public func openPanelClicked() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title != "Settings" }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    @objc private func openSettingsClicked() {
        openPanelClicked()
        viewModel?.showSettings = true
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
