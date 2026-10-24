import Foundation
import SwiftUI
import Combine
import AVFoundation

public enum TransportMode: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case usb = "USB (ADB)"
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

    @Published public var selectedTransport: TransportMode = .wifi {
        didSet {
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
    @Published public var selectedDevice: AudioDevice?
    @Published public var availableDevices: [AudioDevice] = []
    
    @Published public var gainValue: Double {
        didSet {
            UserDefaults.standard.set(gainValue, forKey: "macmic_gain")
            audioEngine.gain = Float(gainValue / 100.0)
        }
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

    // Direct published bindings for SwiftUI UI responsiveness
    @Published public var vuLevel: Float = 0.0
    @Published public var packetsReceived: Int = 0
    @Published public var bytesReceived: Int = 0
    @Published public var connectionState: ConnectionState = .disconnected

    public let audioEngine: AudioEngine
    public let client: MacMicClient

    private var cancellables = Set<AnyCancellable>()

    public init() {
        let savedHost = UserDefaults.standard.string(forKey: "macmic_host") ?? ""
        let savedHistory = UserDefaults.standard.stringArray(forKey: "macmic_ip_history") ?? []
        let savedGain = UserDefaults.standard.object(forKey: "macmic_gain") as? Double ?? 100.0

        self.host = savedHost
        self.selectedADBSerial = UserDefaults.standard.string(forKey: "macmic_adb_serial") ?? ""
        self.ipHistory = savedHistory
        self.gainValue = savedGain

        let engine = AudioEngine()
        engine.gain = Float(savedGain / 100.0)
        self.audioEngine = engine
        self.client = MacMicClient(audioEngine: engine)

        // Bind AudioEngine VU Level directly to AppViewModel
        engine.$vuLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$vuLevel)

        // Bind Client stats and state directly to AppViewModel
        client.$packetsReceived
            .receive(on: DispatchQueue.main)
            .assign(to: &$packetsReceived)

        client.$bytesReceived
            .receive(on: DispatchQueue.main)
            .assign(to: &$bytesReceived)

        client.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        refreshDevices()
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

    public func refreshDevices() {
        self.availableDevices = AudioDeviceManager.getOutputDevices()
        if let def = AudioDeviceManager.getDefaultDevice() {
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
