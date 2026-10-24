import Foundation

public struct ADBDevice: Identifiable, Hashable {
    public var id: String { serial }
    public let serial: String
    public let state: String
    public var model: String = ""

    /// Wireless-debugging entries look like "192.168.1.5:5555"
    public var isWireless: Bool { serial.contains(":") }

    public var displayName: String {
        let name = model.isEmpty ? serial : model.replacingOccurrences(of: "_", with: " ")
        let kind = isWireless ? "Wi-Fi" : "USB"
        return model.isEmpty ? "\(serial) · \(kind)" : "\(name) · \(kind) · \(serial)"
    }
}

public final class ADBHelper {
    public static func findADBPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/Users/\(NSUserName())/Library/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func listDevices() -> [ADBDevice] {
        guard let adb = findADBPath() else { return [] }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["devices", "-l"]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            var devices: [ADBDevice] = []
            let lines = output.components(separatedBy: .newlines)
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // `adb devices -l`: "<serial>   device usb:1-1 product:x model:Pixel_8 device:y transport_id:3"
                let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
                // Only keep usable devices; skip "offline" / "unauthorized" entries
                if parts.count >= 2, parts[1] == "device" {
                    let model = parts.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)) } ?? ""
                    devices.append(ADBDevice(serial: String(parts[0]), state: String(parts[1]), model: model))
                }
            }
            return devices
        } catch {
            return []
        }
    }

    @discardableResult
    public static func forwardPort(localPort: Int = 8125, remotePort: Int = 8125, serial: String? = nil) -> Bool {
        guard let adb = findADBPath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        // With multiple devices attached (e.g. a stale wireless-debugging entry), adb needs -s <serial>.
        var args: [String] = []
        if let serial = serial { args += ["-s", serial] }
        args += ["forward", "tcp:\(localPort)", "tcp:\(remotePort)"]
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @discardableResult
    public static func removeForward(localPort: Int = 8125, serial: String? = nil) -> Bool {
        guard let adb = findADBPath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        var args: [String] = []
        if let serial = serial { args += ["-s", serial] }
        args += ["forward", "--remove", "tcp:\(localPort)"]
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
