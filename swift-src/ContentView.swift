import SwiftUI

// MARK: - Shared Styling

enum MacMicStyle {
    static let cardRadius: CGFloat = 12
    static let innerRadius: CGFloat = 7
    static let cardPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 8
    static let windowWidth: CGFloat = 372
    static let windowHeight: CGFloat = 650
}

/// Grouped-form style card (like System Settings): subtle raised surface with a hairline border.
struct MacMicCardModifier: ViewModifier {
    var padding: CGFloat = MacMicStyle.cardPadding
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MacMicStyle.cardRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacMicStyle.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 0.5)
            )
    }
}

extension View {
    func macMicCard(padding: CGFloat = MacMicStyle.cardPadding) -> some View {
        modifier(MacMicCardModifier(padding: padding))
    }
}

/// Small uppercase-ish section caption used above card contents.
struct SectionCaption: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .labelStyle(.titleAndIcon)
    }
}

/// Native segmented picker with equal, full-width segments. SwiftUI's macOS segmented
/// picker hugs its labels even inside a flexible frame; AppKit's fill distribution does not.
/// The control retains its native radio-group accessibility and keyboard navigation.
struct FullWidthSegmentedPicker<Selection: Equatable>: NSViewRepresentable {
    @Binding var selection: Selection
    let options: [Selection]
    let titles: [String]
    var enabled: Bool = true
    /// Options whose segment is shown but cannot be selected (e.g. unavailable on this OS).
    var disabledOptions: [Selection] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        // SwiftUI may revisit bridged controls during leaf updates. AppKit setters can
        // invalidate layout even for identical values, so leave unchanged chrome alone.
        for (index, title) in titles.enumerated() where control.label(forSegment: index) != title {
            control.setLabel(title, forSegment: index)
        }
        let selected = options.firstIndex(of: selection) ?? -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
        if control.isEnabled != enabled { control.isEnabled = enabled }
        for (index, option) in options.enumerated() {
            let segmentEnabled = !disabledOptions.contains(option)
            if control.isEnabled(forSegment: index) != segmentEnabled {
                control.setEnabled(segmentEnabled, forSegment: index)
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: FullWidthSegmentedPicker
        init(_ parent: FullWidthSegmentedPicker) { self.parent = parent }

        @objc func select(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment]
        }
    }
}

/// Presentational three-way denoise choice; maps onto `denoiseEnabled` + `denoiseMode`.
enum DenoiseChoice: CaseIterable, Equatable {
    case off, rnnoise, apple

    func title(using l10n: LocalizationManager) -> String {
        switch self {
        case .off: return l10n.t("denoise_choice_off")
        case .rnnoise: return l10n.t("denoise_choice_rnnoise")
        case .apple: return l10n.t("denoise_choice_apple")
        }
    }
}

/// Single-line input field look shared by the IP field and the ADB device selector:
/// icon · content · trailing icon button, on a text-field background.
struct FieldContainer<Content: View>: View {
    var disabled: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: MacMicStyle.innerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(disabled ? 0.45 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacMicStyle.innerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Small borderless icon button that lives inside a `FieldContainer`.
struct FieldIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// One line of secondary explanatory text under a field.
struct FieldFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 2)
            .help(text)
    }
}

/// Device name stays legible; technical details live in the field footnote.
struct ADBDeviceLabel: View {
    let device: ADBDevice

    var body: some View {
        HStack(spacing: 6) {
            Text(device.model.isEmpty ? device.serial : device.model.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// Inline hint / warning row with icon.
struct HintRow: View {
    let systemImage: String
    let text: String
    var detail: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 11, weight: detail == nil ? .regular : .medium))
                    .foregroundColor(detail == nil ? .secondary : .primary)
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: MacMicStyle.innerRadius, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

// MARK: - History Row

struct HistoryIPRowView: View {
    let ip: String
    @ObservedObject var vm: AppViewModel
    @ObservedObject var l10n: LocalizationManager
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                vm.host = ip
                vm.showHistoryPopover = false
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(ip)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: {
                vm.removeHistoryIP(ip)
                if vm.ipHistory.isEmpty {
                    vm.showHistoryPopover = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(hovering ? 0.9 : 0.5))
            }
            .buttonStyle(.plain)
            .help(l10n.t("delete"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
    }
}

// MARK: - Status Header

struct StatusHeaderView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var l10n: LocalizationManager

    @State private var settingsHovered = false

    private var stateColor: Color {
        switch vm.connectionState {
        case .streaming: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    private var symbolName: String {
        switch vm.connectionState {
        case .streaming: return "mic.fill"
        case .connecting: return "mic"
        case .error: return "mic.slash.fill"
        case .disconnected: return "mic.slash"
        }
    }

    private var title: String {
        switch vm.connectionState {
        case .streaming: return l10n.t("status_connected")
        case .connecting: return l10n.t("status_connecting")
        case .error: return l10n.t("status_error")
        case .disconnected: return l10n.t("status_disconnected")
        }
    }

    private var subtitle: String {
        switch vm.connectionState {
        case .streaming:
            return "\(vm.selectedTransport.displayName(using: l10n)) · \(vm.selectedDevice?.name ?? l10n.t("app_title"))"
        case .connecting(let d), .error(let d):
            let trimmed = d.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? vm.selectedTransport.displayName(using: l10n) : trimmed
        case .disconnected:
            return l10n.t("status_ready_hint")
        }
    }

    private var isConnecting: Bool {
        if case .connecting = vm.connectionState { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            statusSummary
            Button(action: { vm.showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(settingsHovered ? 0.07 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { settingsHovered = $0 }
            .help(l10n.t("settings"))
            .accessibilityLabel(Text(l10n.t("settings")))
        }
        .animation(.easeInOut(duration: 0.2), value: vm.connectionState)
        .macMicCard()
    }

    private var statusSummary: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(vm.isStreaming ? 0.18 : 0.12))
                Circle()
                    .strokeBorder(stateColor.opacity(0.35), lineWidth: 1)

                if isConnecting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(stateColor)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(vm.connectionState.isError ? .red : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(vm.statusMessage(using: l10n)))
    }
}

private extension ConnectionState {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Level Meter


// MARK: - Content View

public struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var vm = AppViewModel.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    public init() {}

    private var hasBlackHole: Bool {
        vm.availableDevices.contains { Self.isBlackHole($0) }
    }

    static func isBlackHole(_ dev: AudioDevice) -> Bool {
        dev.name.localizedCaseInsensitiveContains("BlackHole")
    }

    private var connectTitle: String {
        vm.isStreaming ? l10n.t("btn_disconnect") : l10n.t("btn_connect")
    }

    public var body: some View {
        VStack(spacing: MacMicStyle.sectionSpacing) {
            StatusHeaderView(vm: vm, l10n: l10n)
            transportCard
            audioCard
            denoiseCard
            levelCard
            connectButton
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .frame(width: MacMicStyle.windowWidth, height: MacMicStyle.windowHeight, alignment: .top)
        .background(
            Color(nsColor: .windowBackgroundColor)
                .overlay(Color.black.opacity(colorScheme == .dark ? 0 : 0.035))
        )
        .preferredColorScheme(l10n.currentTheme.colorScheme)
        .sheet(isPresented: $vm.showSettings) {
            SettingsView()
        }
        .alert(isPresented: $vm.showAlert) {
            Alert(
                title: Text(l10n.t("alert_title")),
                message: Text(vm.alertMessage),
                dismissButton: .default(Text(l10n.t("alert_ok")))
            )
        }
    }

    // MARK: Transport

    private var transportCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(title: l10n.t("transport_header"), systemImage: "antenna.radiowaves.left.and.right")

            FullWidthSegmentedPicker(
                selection: $vm.selectedTransport,
                options: TransportMode.allCases,
                titles: TransportMode.allCases.map { $0.displayName(using: l10n) },
                enabled: !vm.isStreaming
            )
            .frame(height: 24)

            if vm.selectedTransport == .usb {
                adbDevicePicker
                FieldFootnote(text: adbFootnote)
                    .help(l10n.t("usb_hint"))
            } else {
                ipField
            }
        }
        .macMicCard()
    }

    private var adbFootnote: String {
        guard let device = vm.adbDevices.first(where: { $0.serial == vm.selectedADBSerial }) else {
            return l10n.t("usb_hint")
        }
        return "\(device.isWireless ? "Wi-Fi" : "USB") · \(device.serial)"
    }

    private var adbDevicePicker: some View {
        let selected = vm.adbDevices.first(where: { $0.serial == vm.selectedADBSerial })
        return FieldContainer(disabled: vm.isStreaming) {
            Image(systemName: selected?.isWireless == true ? "wifi" : "cable.connector")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 18)

            if vm.adbDevices.isEmpty {
                Text(l10n.t("adb_no_devices"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Menu {
                    ForEach(vm.adbDevices) { dev in
                        Button {
                            vm.selectedADBSerial = dev.serial
                        } label: {
                            if dev.serial == vm.selectedADBSerial {
                                Label(dev.displayName, systemImage: "checkmark")
                            } else {
                                Text(dev.displayName)
                            }
                        }
                    }
                } label: {
                    ADBDeviceLabel(device: selected ?? vm.adbDevices[0])
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(vm.isStreaming)
                .accessibilityLabel(Text(l10n.t("adb_device_label")))
            }

            FieldIconButton(systemImage: "arrow.clockwise", help: l10n.t("adb_refresh")) {
                vm.refreshADBDevices()
            }
            .disabled(vm.isStreaming)
        }
    }

    private var ipField: some View {
        FieldContainer(disabled: vm.isStreaming) {
            Image(systemName: "iphone")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 18)

            TextField(l10n.t("phone_ip_placeholder"), text: $vm.host)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .disabled(vm.isStreaming)
                .accessibilityLabel(Text(l10n.t("phone_ip_label")))

            if !vm.ipHistory.isEmpty {
                FieldIconButton(systemImage: "clock.arrow.circlepath", help: l10n.t("history_ips")) {
                    vm.showHistoryPopover.toggle()
                }
                .disabled(vm.isStreaming)
                .popover(isPresented: $vm.showHistoryPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l10n.t("history_ips"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                        ForEach(vm.ipHistory, id: \.self) { ip in
                            HistoryIPRowView(ip: ip, vm: vm, l10n: l10n)
                        }
                    }
                    .padding(.bottom, 6)
                    .frame(minWidth: 210)
                }
            }
        }
    }

    // MARK: Audio output + gain

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionCaption(title: l10n.t("audio_routing_header"), systemImage: "speaker.wave.2")
                Spacer(minLength: 4)
                if let dev = vm.selectedDevice, Self.isBlackHole(dev) {
                    Label(l10n.t("virtual_mic_tag").trimmingCharacters(in: CharacterSet(charactersIn: " []")),
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            FieldContainer {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                Menu {
                    ForEach(vm.availableDevices) { dev in
                        let title = Self.isBlackHole(dev) ? "\(dev.name) · \(l10n.t("recommended_tag"))" : dev.name
                        Button {
                            vm.selectedDevice = dev
                        } label: {
                            if vm.selectedDevice == dev {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(vm.selectedDevice?.name ?? l10n.t("audio_routing_header"))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text(l10n.t("audio_routing_header")))

                FieldIconButton(systemImage: "arrow.clockwise", help: l10n.t("refresh_devices")) {
                    vm.refreshDevices()
                }
                .focusable(false)
            }

            if !hasBlackHole {
                HintRow(
                    systemImage: "exclamationmark.triangle.fill",
                    text: l10n.t("blackhole_missing"),
                    detail: l10n.t("blackhole_missing_detail"),
                    tint: .orange
                )
            }

            Divider().padding(.vertical, 1)

            gainRow
        }
        .macMicCard()
    }

    // MARK: Denoise

    /// Single three-way view of the (enabled, mode) pair stored in the view model.
    private var denoiseChoice: Binding<DenoiseChoice> {
        Binding(
            get: {
                guard vm.denoiseEnabled else { return .off }
                return vm.denoiseMode == .rnnoise ? .rnnoise : .apple
            },
            set: { choice in
                // Set the mode before enabling so the pushed config never briefly
                // runs the previous engine; skip no-op writes to avoid redundant pushes.
                switch choice {
                case .off:
                    if vm.denoiseEnabled { vm.denoiseEnabled = false }
                case .rnnoise, .apple:
                    let mode: DenoiseMode = choice == .rnnoise ? .rnnoise : .appleVoiceIsolation
                    if vm.denoiseMode != mode { vm.denoiseMode = mode }
                    if !vm.denoiseEnabled { vm.denoiseEnabled = true }
                }
            }
        )
    }

    private var denoiseCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(title: l10n.t("denoise_header"), systemImage: "waveform.badge.minus")

            FullWidthSegmentedPicker(
                selection: denoiseChoice,
                options: DenoiseChoice.allCases,
                titles: DenoiseChoice.allCases.map { $0.title(using: l10n) },
                disabledOptions: vm.isAppleVoiceIsolationAvailable ? [] : [.apple]
            )
            .frame(height: 24)
            .help(vm.isAppleVoiceIsolationAvailable ? "" : l10n.t("denoise_apple_unavailable"))
            .accessibilityLabel(Text(l10n.t("denoise_header")))

            // Always laid out (only dimmed when off) so the card height never changes.
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(l10n.t("denoise_strength"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(vm.denoiseStrength))%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    Slider(value: $vm.denoiseStrength, in: 0...100, step: 5)
                        .controlSize(.small)
                        .accessibilityLabel(Text(l10n.t("denoise_strength")))
                }

                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(!vm.denoiseEnabled
                         ? l10n.t("denoise_info_off")
                         : (vm.denoiseMode == .rnnoise ? l10n.t("denoise_info_rnnoise") : l10n.t("denoise_info_apple")))
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            }
            .disabled(!vm.denoiseEnabled)
            .opacity(vm.denoiseEnabled ? 1 : 0.45)

            Label(l10n.t("denoise_stack_hint_short"), systemImage: "info.circle")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(l10n.t("denoise_stack_hint"))
        }
        .macMicCard()
    }

    private var gainRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l10n.t("gain_label").trimmingCharacters(in: CharacterSet(charactersIn: " :：")))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(vm.gainValue))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(vm.isMuted ? .secondary : (vm.gainValue > 100 ? .orange : .primary))
            }

            HStack(spacing: 8) {
                Button(action: { vm.isMuted.toggle() }) {
                    Image(systemName: vm.isMuted ? "speaker.slash.fill" : speakerSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(vm.isMuted ? .red : .accentColor)
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill((vm.isMuted ? Color.red : Color.accentColor).opacity(0.12))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(vm.isMuted ? l10n.t("unmute") : l10n.t("mute_toggle"))
                .accessibilityLabel(Text(l10n.t("mute_toggle")))
                .accessibilityValue(Text(vm.isMuted ? "1" : "0"))

                Slider(value: $vm.gainValue, in: 0...200, step: 5)
                    .controlSize(.small)
                    .disabled(vm.isMuted)
                    .accessibilityLabel(Text(l10n.t("gain_label")))
            }
        }
    }

    private var speakerSymbol: String {
        switch vm.gainValue {
        case ..<1: return "speaker.fill"
        case ..<70: return "speaker.wave.1.fill"
        case ..<140: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    // MARK: Level meter + stats

    private var levelCard: some View {
        LevelCardContent(meter: vm.meter, l10n: l10n, isStreaming: vm.isStreaming, isMuted: vm.isMuted)
            .animation(.easeInOut(duration: 0.2), value: vm.isStreaming)
            .macMicCard()
    }


    // MARK: Primary action

    @ViewBuilder
    private var connectButton: some View {
        let label = HStack(spacing: 6) {
            Spacer()
            Image(systemName: vm.isStreaming ? "stop.fill" : "play.fill")
                .font(.system(size: 12, weight: .bold))
            Text(connectTitle)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        if #available(macOS 26, *) {
            Button(action: { vm.toggleConnect() }) { label }
                .buttonStyle(.glassProminent)
                .tint(vm.isStreaming ? .red : .accentColor)
                .controlSize(.large)
                .accessibilityLabel(Text(connectTitle))
        } else {
            Button(action: { vm.toggleConnect() }) { label }
                .buttonStyle(.borderedProminent)
                .tint(vm.isStreaming ? .red : .accentColor)
                .controlSize(.large)
                .accessibilityLabel(Text(connectTitle))
        }
    }
}

/// Level card. Static chrome lives here; only the small `LiveLevelBar` / `LiveLevelReadout`
/// subviews observe the meter, so a meter tick redraws one Canvas and (≤4×/s) one Text.
struct LevelCardContent: View {
    let meter: MeterModel
    @ObservedObject var l10n: LocalizationManager
    let isStreaming: Bool
    let isMuted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SectionCaption(title: l10n.t("vu_meter_header"), systemImage: "waveform")
                Spacer()
                if isStreaming { ReceivedBytesText(meter: meter, helpText: l10n.t("stats_received")) }
                LiveLevelReadout(meter: meter, l10n: l10n, active: isStreaming && !isMuted)
            }
            LiveLevelBar(meter: meter, active: isStreaming && !isMuted)
            LevelScale()
        }
    }
}

/// dBFS positions shown under the bar (meter spans -60...0 dBFS).
private let meterScaleMarks: [Int] = [-60, -40, -20, -12, -6, 0]

struct LiveLevelBar: View {
    @ObservedObject var meter: MeterModel
    let active: Bool

    private static func x(_ db: Float, _ width: CGFloat) -> CGFloat {
        width * CGFloat((db - AudioEngine.meterFloorDB) / -AudioEngine.meterFloorDB)
    }

    var body: some View {
        let level = active ? meter.reading.level : 0
        let peak = active ? meter.reading.peak : 0
        Canvas { ctx, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            ctx.fill(track, with: .color(Color.primary.opacity(0.08)))
            ctx.clip(to: track)

            if level > 0 {
                // Colour zones by absolute dBFS: green < -12, yellow -12...-6, red > -6.
                let w = size.width
                let gradient = Gradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: Self.x(-14, w) / w),
                    .init(color: .yellow, location: Self.x(-9, w) / w),
                    .init(color: .orange, location: Self.x(-5, w) / w),
                    .init(color: .red, location: 1),
                ])
                ctx.fill(Path(CGRect(x: 0, y: 0, width: w * CGFloat(level), height: size.height)),
                         with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
            }
            if peak > 0.01 {
                let px = max(1.5, size.width * CGFloat(peak) - 1.5)
                let color: Color = peak > 0.9 ? .red : (peak > 0.8 ? .yellow : Color.primary.opacity(0.7))
                ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(color))
            }
            // Faint ticks at the scale marks.
            for db in meterScaleMarks.dropFirst().dropLast() {
                let tx = Self.x(Float(db), size.width)
                ctx.fill(Path(CGRect(x: tx, y: 0, width: 0.5, height: size.height)),
                         with: .color(Color.primary.opacity(0.18)))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

struct LevelScale: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(meterScaleMarks, id: \.self) { db in
                Text(db == 0 ? "0" : "\(db)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                    .fixedSize()
                    .position(x: min(max(geo.size.width * CGFloat(Float(db) / AudioEngine.meterFloorDB * -1 + 1) , 8), geo.size.width - 6),
                              y: geo.size.height / 2)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

struct LiveLevelReadout: View {
    @ObservedObject var meter: MeterModel
    @ObservedObject var l10n: LocalizationManager
    let active: Bool

    var body: some View {
        Text(active ? (meter.readoutDB.map { "\($0) dBFS" } ?? l10n.t("level_idle")) : l10n.t("level_idle"))
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(minWidth: 64, alignment: .trailing)
    }
}

struct ReceivedBytesText: View {
    @ObservedObject var meter: MeterModel
    let helpText: String

    var body: some View {
        let bytes = Double(meter.bytes)
        Text(bytes >= 1024 * 1024 ? String(format: "%.1f MB", bytes / 1_048_576) : String(format: "%.0f KB", bytes / 1024))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.75))
            .help(helpText)
    }
}
