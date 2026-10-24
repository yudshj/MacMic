import SwiftUI

// MARK: - Shared Styling

enum MacMicStyle {
    static let cardRadius: CGFloat = 12
    static let innerRadius: CGFloat = 7
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let windowWidth: CGFloat = 372
    static let windowHeight: CGFloat = 600
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
        case .streaming(let d), .connecting(let d), .error(let d):
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
            .frame(width: 46, height: 46)
            // Subtle live "pulse" ring driven by the audio level while streaming.
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(vm.isStreaming ? 0.45 : 0), lineWidth: 2)
                    .scaleEffect(1.0 + CGFloat(vm.isStreaming ? vm.vuLevel : 0) * 0.22)
                    .animation(.easeOut(duration: 0.12), value: vm.vuLevel)
            )

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

            Image(systemName: vm.selectedTransport.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .help(vm.selectedTransport.displayName(using: l10n))
        }
        .animation(.easeInOut(duration: 0.2), value: vm.connectionState)
        .macMicCard()
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

struct SegmentedLevelMeter: View {
    let level: Float
    let active: Bool
    var segments: Int = 28

    @State private var peak: Float = 0
    @State private var peakTime: Date = .distantPast

    private func color(for index: Int) -> Color {
        let pos = Double(index) / Double(segments)
        if pos >= 0.88 { return .red }        // > ~ -6 dBFS
        if pos >= 0.70 { return .yellow }     // > ~ -15 dBFS
        return .green
    }

    var body: some View {
        let lit = active ? Int((Double(level) * Double(segments)).rounded()) : 0
        let peakIndex = active ? min(segments - 1, Int((Double(peak) * Double(segments)).rounded()) - 1) : -1

        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let isOn = i < lit
                let isPeak = i == peakIndex && i >= lit
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isOn || isPeak ? color(for: i) : Color.primary.opacity(0.09))
                    .opacity(isPeak ? 0.75 : 1)
            }
        }
        .frame(height: 12)
        .animation(.linear(duration: 0.05), value: lit)
        .onChange(of: level) { newValue in
            let now = Date()
            if newValue >= peak {
                peak = newValue
                peakTime = now
            } else if now.timeIntervalSince(peakTime) > 0.9 {
                peak = max(newValue, peak - 0.04)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Content View

public struct ContentView: View {
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
            topBar
            StatusHeaderView(vm: vm, l10n: l10n)
            transportCard
            audioCard
            levelCard
            Spacer(minLength: 0)
            connectButton
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
        .frame(width: MacMicStyle.windowWidth, height: MacMicStyle.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: Top bar (sits alongside the traffic lights)

    private var topBar: some View {
        ZStack {
            Text(l10n.t("app_title"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))

            HStack {
                Spacer()
                Button(action: { vm.showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(l10n.t("settings"))
                .accessibilityLabel(Text(l10n.t("settings")))
            }
        }
        .frame(height: 22)
    }

    // MARK: Transport

    private var transportCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(title: l10n.t("transport_header"), systemImage: "antenna.radiowaves.left.and.right")

            Picker("", selection: $vm.selectedTransport) {
                ForEach(TransportMode.allCases) { mode in
                    Text(mode.displayName(using: l10n)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(vm.isStreaming)

            if vm.selectedTransport == .usb {
                adbDevicePicker
                HintRow(systemImage: "cable.connector", text: l10n.t("usb_hint"))
            } else {
                ipField
            }
        }
        .macMicCard()
    }

    private var adbDevicePicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "smartphone")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)

            if vm.adbDevices.isEmpty {
                Text(l10n.t("adb_no_devices"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("", selection: $vm.selectedADBSerial) {
                    ForEach(vm.adbDevices) { dev in
                        Text(dev.displayName).tag(dev.serial)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .disabled(vm.isStreaming)
                .accessibilityLabel(Text(l10n.t("adb_device_label")))
            }

            Button(action: { vm.refreshADBDevices() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .focusable(false)
            .disabled(vm.isStreaming)
            .help(l10n.t("adb_refresh"))
            .accessibilityLabel(Text(l10n.t("adb_refresh")))
        }
    }

    private var ipField: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.leading, 8)

            TextField(l10n.t("phone_ip_placeholder"), text: $vm.host)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .disabled(vm.isStreaming)
                .padding(.vertical, 6)
                .accessibilityLabel(Text(l10n.t("phone_ip_label")))

            if !vm.ipHistory.isEmpty {
                Button(action: { vm.showHistoryPopover.toggle() }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.isStreaming)
                .help(l10n.t("history_ips"))
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
                .padding(.trailing, 3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MacMicStyle.innerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(vm.isStreaming ? 0.5 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacMicStyle.innerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: Audio output + gain

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(title: l10n.t("audio_routing_header"), systemImage: "speaker.wave.2")

            HStack(spacing: 6) {
                Picker("", selection: $vm.selectedDevice) {
                    ForEach(vm.availableDevices) { dev in
                        if Self.isBlackHole(dev) {
                            Text("\(dev.name)  ·  \(l10n.t("recommended_tag"))").tag(Optional(dev))
                        } else {
                            Text(dev.name).tag(Optional(dev))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Button(action: { vm.refreshDevices() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .focusable(false)
                .help(l10n.t("refresh_devices"))
                .accessibilityLabel(Text(l10n.t("refresh_devices")))
            }

            if let dev = vm.selectedDevice, Self.isBlackHole(dev) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text(l10n.t("virtual_mic_tag").trimmingCharacters(in: CharacterSet(charactersIn: " []")))
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 10.5, weight: .medium))
            } else if !hasBlackHole {
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

    private var levelText: String {
        guard vm.isStreaming, vm.vuLevel > 0.001 else { return l10n.t("level_idle") }
        let db = Double(vm.vuLevel) * 50.0 - 50.0
        return String(format: "%.0f dB", db)
    }

    private var kbText: String {
        let bytes = Double(vm.bytesReceived)
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        }
        return String(format: "%.0f KB", bytes / 1024)
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption(title: l10n.t("vu_meter_header"), systemImage: "waveform")
                Spacer()
                Text(levelText)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            SegmentedLevelMeter(level: vm.isMuted ? 0 : vm.vuLevel, active: vm.isStreaming)

            if vm.isStreaming {
                HStack(spacing: 14) {
                    statItem(icon: "shippingbox", label: l10n.t("stats_packets"), value: "\(vm.packetsReceived)")
                    statItem(icon: "arrow.down.circle", label: l10n.t("stats_received"), value: kbText)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isStreaming)
        .macMicCard()
    }

    private func statItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
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
