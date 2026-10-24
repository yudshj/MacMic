import Foundation
import SwiftUI
import AppKit
import Combine
import AVFoundation

public enum TransportMode: String, CaseIterable, Identifiable {
    case usb = "USB (ADB)"
    case wifi = "Wi-Fi"
    case wifiDirect = "Wi-Fi Direct"

    public var id: String { rawValue }

    public func displayName(using l10n: LocalizationManager) -> String {
        switch self {
        case .wifi: return l10n.t("transport_wifi")
        case .usb: return l10n.t("transport_usb")
        case .wifiDirect: return l10n.t("transport_wifi_direct")
        }
    }

    public var icon: String {
        switch self {
        case .wifi: return "wifi"
        case .usb: return "cable.connector"
        case .wifiDirect: return "personalhotspot"
        }
    }
}

public final class AppViewModel: ObservableObject {
    public static let shared = AppViewModel()

    @Published public var host: String {
        didSet {
            UserDefaults.standard.set(host, forKey: "macmic_host")
        }
    }
    @Published public var ipHistory: [String] = []

    @Published public var selectedTransport: TransportMode = .usb {
        didSet {
            UserDefaults.standard.set(selectedTransport.rawValue, forKey: "macmic_transport")
            if selectedTransport == .usb {
                host = "127.0.0.1"
                refreshADBDevices()
            } else if selectedTransport == .wifiDirect && (host == "127.0.0.1" || host.isEmpty) {
                host = "192.168.49.1"
            }
        }
    }
    @Published public var adbDevices: [ADBDevice] = []
    @Published public var selectedADBSerial: String = "" {
        didSet { UserDefaults.standard.set(selectedADBSerial, forKey: "macmic_adb_serial") }
    }
    @Published public var selectedDevice: AudioDevice? {
        didSet {
            guard let uid = selectedDevice?.uid else { return }
            UserDefaults.standard.set(uid, forKey: "macmic_output_uid")
            audioEngine.currentDevice = selectedDevice
        }
    }
    @Published public var availableDevices: [AudioDevice] = []
    
    @Published public var gainValue: Double {
        didSet {
            UserDefaults.standard.set(gainValue, forKey: "macmic_gain")
            audioEngine.gain = Float(gainValue / 100.0)
        }
    }
    // MARK: Denoise (persisted)
    @Published public var denoiseEnabled: Bool {
        didSet { UserDefaults.standard.set(denoiseEnabled, forKey: "macmic_denoise_enabled"); pushDenoiseConfig() }
    }
    @Published public var denoiseMode: DenoiseMode {
        didSet { UserDefaults.standard.set(denoiseMode.rawValue, forKey: "macmic_denoise_mode"); pushDenoiseConfig() }
    }
    /// 0...100 %, wet/dry mix against the latency-aligned original.
    @Published public var denoiseStrength: Double {
        didSet { UserDefaults.standard.set(denoiseStrength, forKey: "macmic_denoise_strength"); pushDenoiseConfig() }
    }
    public let isAppleVoiceIsolationAvailable = DenoiseProcessor.isAppleVoiceIsolationAvailable

    /// Approximate extra latency of the selected denoiser, for display.
    public var denoiseLatencyMs: Int {
        guard denoiseEnabled else { return 0 }
        switch denoiseMode {
        case .rnnoise: return 20
        case .appleVoiceIsolation: return 56
        }
    }

    private func pushDenoiseConfig() {
        audioEngine.denoiser.setConfig(DenoiseConfig(
            enabled: denoiseEnabled,
            mode: denoiseMode,
            strength: Float(denoiseStrength / 100.0)))
    }

    @Published public var isMuted: Bool = false {
        didSet {
            audioEngine.isMuted = isMuted
        }
    }

    @Published public var showAlert: Bool = false
    @Published public var alertMessage: String = ""
    @Published public var showSettings: Bool = false
    @Published public var showHistoryPopover: Bool = false

    /// High-frequency meter data lives in its own object so only the meter views re-render,
    /// not the whole window (pickers, cards...) many times per second.
    public let meter = MeterModel()
    @Published public var connectionState: ConnectionState = .disconnected

    public let audioEngine: AudioEngine
    public let client: MacMicClient

    private var cancellables = Set<AnyCancellable>()

    public init() {
        let savedHost = UserDefaults.standard.string(forKey: "macmic_host") ?? ""
        let savedHistory = UserDefaults.standard.stringArray(forKey: "macmic_ip_history") ?? []
        let savedGain = UserDefaults.standard.object(forKey: "macmic_gain") as? Double ?? 100.0

        self.host = savedHost
        // USB (ADB) is the default transport; remember the user's last choice.
        self.selectedTransport = TransportMode(rawValue: UserDefaults.standard.string(forKey: "macmic_transport") ?? "") ?? .usb
        let defaults = UserDefaults.standard
        self.denoiseEnabled = defaults.object(forKey: "macmic_denoise_enabled") as? Bool ?? true
        // Apple Voice Isolation measured both stronger and cheaper than RNNoise; RNNoise stays
        // available (and becomes the default when AUSoundIsolation is unavailable, macOS < 13).
        self.denoiseMode = DenoiseMode(rawValue: defaults.string(forKey: "macmic_denoise_mode") ?? "") ?? .appleVoiceIsolation
        self.denoiseStrength = defaults.object(forKey: "macmic_denoise_strength") as? Double ?? 100.0
        self.selectedADBSerial = UserDefaults.standard.string(forKey: "macmic_adb_serial") ?? ""
        self.ipHistory = savedHistory
        self.gainValue = savedGain

        let engine = AudioEngine()
        engine.gain = Float(savedGain / 100.0)
        self.audioEngine = engine
        self.client = MacMicClient(audioEngine: engine)

        // Meter: quantise to the meter's resolution and drop repeats, and stop updating
        // entirely while the window is hidden / occluded.
        let meter = self.meter
        engine.$vuLevel
            .combineLatest(engine.$vuPeak)
            .map { level, peak in
                let q = Float(MeterModel.levelSteps)
                return MeterReading(level: (level * q).rounded() / q, peak: (peak * q).rounded() / q)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { reading in if meter.isVisible { meter.reading = reading } }
            .store(in: &cancellables)

        // The numeric dB readout changes at most 4×/s so it stays legible.
        engine.$vuLevel
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .map { level -> Int? in
                level <= 0.001 ? nil : Int((level * -AudioEngine.meterFloorDB + AudioEngine.meterFloorDB).rounded())
            }
            .removeDuplicates()
            .sink { db in if meter.isVisible { meter.readoutDB = db } }
            .store(in: &cancellables)

        client.$bytesReceived
            .throttle(for: .milliseconds(1000), scheduler: DispatchQueue.main, latest: true)
            .sink { bytes in if meter.isVisible || bytes == 0 { meter.bytes = bytes } }
            .store(in: &cancellables)

        client.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        refreshDevices()
        if selectedTransport == .usb { refreshADBDevices() }
        if denoiseMode == .appleVoiceIsolation && !isAppleVoiceIsolationAvailable { denoiseMode = .rnnoise }
        pushDenoiseConfig()
    }

    public func saveToHistory(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "127.0.0.1", trimmed != "192.168.49.1" else { return }
        var list = ipHistory.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > 10 {
            list = Array(list.prefix(10))
        }
        self.ipHistory = list
        UserDefaults.standard.set(list, forKey: "macmic_ip_history")
    }

    public func removeHistoryIP(_ ip: String) {
        self.ipHistory.removeAll { $0 == ip }
        UserDefaults.standard.set(self.ipHistory, forKey: "macmic_ip_history")
    }

    /// Re-enumerates output devices, keeping the current selection (or the last one used, by UID)
    /// when it is still attached; only falls back to auto-detect (prefers BlackHole) if it is gone.
    public func refreshDevices() {
        self.availableDevices = AudioDeviceManager.getOutputDevices()
        let savedUID = UserDefaults.standard.string(forKey: "macmic_output_uid") ?? ""
        let wanted = selectedDevice?.uid.isEmpty == false ? selectedDevice!.uid : savedUID
        if let kept = availableDevices.first(where: { $0.uid == wanted }) {
            if selectedDevice?.id != kept.id { selectedDevice = kept }
            audioEngine.currentDevice = kept
        } else if let def = AudioDeviceManager.getDefaultDevice() {
            self.selectedDevice = def
            self.audioEngine.currentDevice = def
        }
    }

    /// Re-scan `adb devices` off the main thread and keep the user's choice when still attached.
    public func refreshADBDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let devs = ADBHelper.listDevices()
            DispatchQueue.main.async {
                self.adbDevices = devs
                if !devs.contains(where: { $0.serial == self.selectedADBSerial }) {
                    // Prefer a USB-attached device over stale wireless-debugging entries
                    self.selectedADBSerial = (devs.first(where: { !$0.isWireless }) ?? devs.first)?.serial ?? ""
                }
            }
        }
    }

    public var isStreaming: Bool {
        if case .streaming = connectionState { return true }
        return false
    }

    public var statusColor: Color {
        switch connectionState {
        case .streaming: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    public func statusMessage(using l10n: LocalizationManager) -> String {
        switch connectionState {
        case .streaming(let detail):
            return "\(l10n.t("status_connected")) - \(detail)"
        case .connecting(let detail):
            return "\(l10n.t("status_connecting")) \(detail)"
        case .error(let err):
            return "\(l10n.t("status_error")): \(err)"
        case .disconnected:
            return l10n.t("status_disconnected")
        }
    }

    public func toggleConnect() {
        let l10n = LocalizationManager.shared
        if isStreaming {
            client.disconnect()
            if selectedTransport == .usb {
                ADBHelper.removeForward(localPort: 8125, serial: selectedADBSerial.isEmpty ? nil : selectedADBSerial)
            }
        } else {
            // Prompt macOS Microphone Access Permission Dialog if not granted
            AVCaptureDevice.requestAccess(for: .audio) { _ in }

            if let dev = selectedDevice {
                audioEngine.currentDevice = dev
            }
            if selectedTransport == .usb {
                let devs = ADBHelper.listDevices()
                adbDevices = devs
                if devs.isEmpty {
                    alertMessage = l10n.t("alert_no_adb_device")
                    showAlert = true
                    return
                }
                // Use the device picked in the UI; otherwise prefer USB over wireless entries
                let target = devs.first(where: { $0.serial == selectedADBSerial })
                    ?? devs.first(where: { !$0.isWireless }) ?? devs[0]
                selectedADBSerial = target.serial
                if !ADBHelper.forwardPort(localPort: 8125, remotePort: 8125, serial: target.serial) {
                    alertMessage = l10n.t("alert_adb_forward_failed")
                    showAlert = true
                    return
                }
                client.connect(host: "127.0.0.1", isUSB: true)
            } else {
                let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !targetHost.isEmpty else {
                    alertMessage = l10n.t("alert_empty_ip")
                    showAlert = true
                    return
                }
                saveToHistory(ip: targetHost)
                client.connect(host: targetHost, isUSB: false)
            }
        }
    }
}

/// Live meter values, observed only by the small meter views.
public final class MeterModel: ObservableObject {
    /// Meter values are quantised to 1/120 of full scale (0.5 dB) before publishing.
    public static let levelSteps = 120

    @Published public var reading = MeterReading(level: 0, peak: 0)
    /// Rounded dBFS for the numeric readout (nil = no signal); updated ≤ 4×/s.
    @Published public var readoutDB: Int?
    @Published public var bytes: Int = 0

    public var level: Float { reading.level }

    /// False while every window is occluded/minimised: meter updates are skipped (zero UI cost).
    public private(set) var isVisible = true
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let update: (Notification) -> Void = { [weak self] _ in self?.refreshVisibility() }
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main, using: update))
        observers.append(center.addObserver(forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main, using: update))
    }

    private func refreshVisibility() {
        let visible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && !($0 is NSPanel) }
        // With no window at all (closed; its UI is released) there is nothing to draw:
        // skip meter work entirely so the audio thread does not wake the main thread.
        if !visible && AppDelegate.mainWindow == nil {
            if isVisible { isVisible = false; reading = MeterReading(level: 0, peak: 0); readoutDB = nil }
            return
        }
        if visible != isVisible {
            isVisible = visible
            if !visible { reading = MeterReading(level: 0, peak: 0); readoutDB = nil }
        }
    }
}

public struct MeterReading: Equatable {
    public var level: Float   // 0...1 over -60...0 dBFS
    public var peak: Float
}
