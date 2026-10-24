import Foundation
import Network
import QuartzCore

public enum ConnectionState: Equatable {
    case disconnected
    case connecting(String)
    case streaming(String)
    case error(String)
}

public final class MacMicClient: ObservableObject {
    @Published public var state: ConnectionState = .disconnected
    @Published public var packetsReceived: Int = 0
    @Published public var bytesReceived: Int = 0

    private var host: String
    private var port: Int
    private var isUSBMode: Bool
    /// Reassembly buffer for media frames multiplexed on the TCP control channel (USB/ADB mode).
    private var tcpStreamBuf: [UInt8] = []

    public let audioEngine: AudioEngine
    private var opusDecoder: OpusDecoderWrapper?

    private var isRunning: Bool = false
    private var tcpSocketFd: Int32 = -1
    private var udpSocketFd: Int32 = -1
    private var serverSockAddr = sockaddr_in()

    private let workerQueue = DispatchQueue(label: "com.macmic.client.worker", qos: .userInteractive)
    private let pollQueue = DispatchQueue(label: "com.macmic.client.poll", qos: .utility)

    private var totalPktsCount = 0
    private var totalBytesCount = 0
    private var lastStatsUpdate: CFTimeInterval = 0

    // Protocol Constants
    private let CMD_CHECK_VERSION: UInt8 = 0x65   // 101
    private let CMD_SET_CODEC_PARAM: UInt8 = 0x66 // 102
    private let CMD_START_CAPTURE: UInt8 = 0x67   // 103
    private let CMD_STOP_CAPTURE: UInt8 = 0x68    // 104
    private let CMD_HEARTBEAT: UInt8 = 0x69       // 105

    public init(
        host: String = "127.0.0.1",
        port: Int = 8125,
        isUSBMode: Bool = false,
        audioEngine: AudioEngine
    ) {
        self.host = host
        self.port = port
        self.isUSBMode = isUSBMode
        self.audioEngine = audioEngine
    }

    public func connect(host: String, isUSB: Bool = false) {
        disconnect()
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isUSBMode = isUSB
        self.tcpStreamBuf.removeAll(keepingCapacity: true)
        self.isRunning = true
        self.totalPktsCount = 0
        self.totalBytesCount = 0
        self.packetsReceived = 0
        self.bytesReceived = 0

        updateState(.connecting("正在连接 \(self.host):\(port)..."))

        workerQueue.async { [weak self] in
            self?.runConnectFlow()
        }
    }

    private func updateState(_ newState: ConnectionState) {
        DispatchQueue.main.async {
            self.state = newState
        }
    }

    @discardableResult
    private func sendPacketTCP(type: UInt8, payload: Data = Data()) -> Bool {
        guard tcpSocketFd >= 0 else { return false }
        
        // 1. Send cmd (1 byte)
        var cmd = type
        var sent = send(tcpSocketFd, &cmd, 1, 0)
        if sent != 1 { return false }
        
        // 2. Send length (4 bytes BE)
        var lenBytes = UInt32(payload.count).bigEndian
        sent = withUnsafeBytes(of: &lenBytes) { ptr in
            send(tcpSocketFd, ptr.baseAddress!, 4, 0)
        }
        if sent != 4 { return false }
        
        // 3. Send payload
        if !payload.isEmpty {
            let pSent = payload.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return send(tcpSocketFd, base, payload.count, 0)
            }
            if pSent != payload.count { return false }
        }
        return true
    }

    private func runConnectFlow() {
        signal(SIGPIPE, SIG_IGN)

        self.opusDecoder = OpusDecoderWrapper(sampleRate: 48000, channels: 1)

        // 1. Create TCP Socket for Handshake & Control
        let tFd = socket(AF_INET, SOCK_STREAM, 0)
        guard tFd >= 0 else {
            updateState(.error("创建TCP套接字失败"))
            return
        }
        self.tcpSocketFd = tFd

        var opt: Int32 = 1
        setsockopt(tFd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(tFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(tFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var servAddr = sockaddr_in()
        servAddr.sin_family = sa_family_t(AF_INET)
        servAddr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &servAddr.sin_addr)
        self.serverSockAddr = servAddr

        let connRes = withUnsafePointer(to: &servAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Foundation.connect(tFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connRes == 0 else {
            close(tFd)
            self.tcpSocketFd = -1
            updateState(.error("无法连接到手机 TCP:\(port)"))
            return
        }

        // 2. Handshake Sequence (0x65 -> 0x66 -> 0x67)
        // 0x65: Version check [proto_ver=4, client_maj=6, client_min=3, 0, 0, 0]
        let vPayload = Data([0x04, 0x06, 0x03, 0x00, 0x00, 0x00])
        guard sendPacketTCP(type: CMD_CHECK_VERSION, payload: vPayload), readTCPResponse() != nil else {
            disconnect()
            updateState(.error("握手 0x65 失败"))
            return
        }

        // 0x66: Codec & client media UDP port
        // Payload: [codec=0x02, srIndex=0x02 (48k), clientMediaPort(4 BE)]
        var codecPayload = Data([0x02, 0x02])
        let clientMediaPort = UInt32(port)
        codecPayload.append(UInt8((clientMediaPort >> 24) & 0xFF))
        codecPayload.append(UInt8((clientMediaPort >> 16) & 0xFF))
        codecPayload.append(UInt8((clientMediaPort >> 8) & 0xFF))
        codecPayload.append(UInt8(clientMediaPort & 0xFF))
        guard sendPacketTCP(type: CMD_SET_CODEC_PARAM, payload: codecPayload), readTCPResponse() != nil else {
            disconnect()
            updateState(.error("配置音频 0x66 失败"))
            return
        }

        // 0x67: Start audio capture
        guard sendPacketTCP(type: CMD_START_CAPTURE, payload: Data()), readTCPResponse() != nil else {
            disconnect()
            updateState(.error("启动采集 0x67 失败"))
            return
        }

        // 3. Create UDP Socket for Media
        let uFd = socket(AF_INET, SOCK_DGRAM, 0)
        if uFd >= 0 {
            self.udpSocketFd = uFd
            var reuse: Int32 = 1
            setsockopt(uFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(uFd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
            
            var localAddr = sockaddr_in()
            localAddr.sin_family = sa_family_t(AF_INET)
            localAddr.sin_port = in_port_t(port).bigEndian
            localAddr.sin_addr.s_addr = in_addr_t(0)
            
            let bRes = withUnsafePointer(to: &localAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(uFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            
            if bRes != 0 {
                var fallbackAddr = sockaddr_in()
                fallbackAddr.sin_family = sa_family_t(AF_INET)
                fallbackAddr.sin_port = 0
                fallbackAddr.sin_addr.s_addr = in_addr_t(0)
                _ = withUnsafePointer(to: &fallbackAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        bind(uFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            
            // Send initial trigger packet to punch UDP hole
            sendUDPPing()
        }

        // 4. Start Audio Engine
        DispatchQueue.main.async {
            self.audioEngine.start()
        }

        // 5. Start Keepalive Heartbeat Loop (TCP 0x69 every 2s + UDP Ping)
        startPollLoop()

        updateState(.streaming("麦克风工作中 (\(host))"))

        // 6. Receive Loop (Select on both TCP and UDP)
        runReceiveLoop()
    }
    
    private func sendUDPPing() {
        guard udpSocketFd >= 0 else { return }
        var trigger: [UInt8] = [0x00, 0x04, 0x00, 0x00]
        var target = serverSockAddr
        withUnsafePointer(to: &target) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sPtr in
                sendto(udpSocketFd, &trigger, trigger.count, 0, sPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func readTCPResponse() -> Data? {
        guard tcpSocketFd >= 0 else { return nil }
        var cmd: UInt8 = 0
        if recv(tcpSocketFd, &cmd, 1, 0) <= 0 { return nil }
        
        var lenBE: UInt32 = 0
        var recvd = 0
        while recvd < 4 {
            let n = withUnsafeMutableBytes(of: &lenBE) { ptr in
                recv(tcpSocketFd, ptr.baseAddress! + recvd, 4 - recvd, 0)
            }
            if n <= 0 { return nil }
            recvd += n
        }
        
        let len = Int(UInt32(bigEndian: lenBE))
        if len > 0 {
            var payload = [UInt8](repeating: 0, count: len)
            var pRecvd = 0
            while pRecvd < len {
                let n = recv(tcpSocketFd, &payload[pRecvd], len - pRecvd, 0)
                if n <= 0 { return nil }
                pRecvd += n
            }
            return Data(payload)
        }
        return Data()
    }

    private func runReceiveLoop() {
        var tcpBuf = [UInt8](repeating: 0, count: 2048)
        var udpBuf = [UInt8](repeating: 0, count: 2048)

        while isRunning {
            var readFds = fd_set()
            fdZero(&readFds)
            
            var maxFd: Int32 = -1
            if tcpSocketFd >= 0 {
                fdSet(tcpSocketFd, &readFds)
                maxFd = max(maxFd, tcpSocketFd)
            }
            if udpSocketFd >= 0 {
                fdSet(udpSocketFd, &readFds)
                maxFd = max(maxFd, udpSocketFd)
            }
            
            if maxFd < 0 { break }
            
            var tv = timeval(tv_sec: 0, tv_usec: 500_000)
            let sel = select(maxFd + 1, &readFds, nil, nil, &tv)
            
            guard isRunning else { break }
            
            if sel > 0 {
                // Check UDP (Media stream)
                if udpSocketFd >= 0 && fdIsSet(udpSocketFd, &readFds) {
                    var srcAddr = sockaddr_in()
                    var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sPtr in
                            recvfrom(udpSocketFd, &udpBuf, udpBuf.count, 0, sPtr, &srcLen)
                        }
                    }
                    if n > 0 {
                        handleMediaPacket(data: Data(udpBuf[0..<n]))
                    }
                }
                
                // Check TCP (Control channel disconnect detection)
                if tcpSocketFd >= 0 && fdIsSet(tcpSocketFd, &readFds) {
                    let n = recv(tcpSocketFd, &tcpBuf, tcpBuf.count, 0)
                    if n <= 0 {
                        // Remote phone disconnected TCP channel
                        NSLog("[MacMic] Phone disconnected TCP control channel")
                        disconnect()
                        break
                    }
                    // USB (ADB) mode: the phone multiplexes audio onto the control TCP stream.
                    // Frames are [type(1)][len(4 BE)][len bytes]; type 0x04 carries a media packet
                    // with the same layout as a Wi-Fi UDP datagram (Opus payload at offset 11).
                    if isUSBMode {
                        tcpStreamBuf.append(contentsOf: tcpBuf[0..<n])
                        drainTCPFrames()
                    }
                }
            }
        }
    }

    /// Splits the USB-mode TCP stream into frames. Two framings are interleaved on the socket:
    ///  - media:   [0x04 0x00][len u16 BE][seq u16][ts u32][flag u8][opus...]  total = 4 + len
    ///            (byte-identical to a Wi-Fi UDP datagram, Opus payload at offset 11)
    ///  - control: [type u8 (0x65...0x69)][len u32 BE][status + data]           total = 5 + len
    private func drainTCPFrames() {
        var offset = 0
        let buf = tcpStreamBuf
        while buf.count - offset >= 4 {
            let total: Int
            let isMedia = buf[offset] == 0x04 && buf[offset + 1] == 0x00
            if isMedia {
                total = 4 + (Int(buf[offset + 2]) << 8 | Int(buf[offset + 3]))
            } else if (0x65...0x69).contains(buf[offset]) {
                guard buf.count - offset >= 5 else { break }
                let len = Int(buf[offset + 1]) << 24 | Int(buf[offset + 2]) << 16
                        | Int(buf[offset + 3]) << 8 | Int(buf[offset + 4])
                guard len < 64 * 1024 else { return resyncTCPStream() }
                total = 5 + len
            } else {
                return resyncTCPStream()
            }
            guard buf.count - offset >= total else { break }
            if isMedia {
                handleMediaPacket(data: Data(buf[offset..<(offset + total)]))
            }
            offset += total
        }
        if offset > 0 { tcpStreamBuf.removeFirst(offset) }
    }

    /// Framing lost: skip ahead to the next plausible media header (0x04 0x00) and keep going.
    private func resyncTCPStream() {
        var i = 1
        while i + 1 < tcpStreamBuf.count, !(tcpStreamBuf[i] == 0x04 && tcpStreamBuf[i + 1] == 0x00) { i += 1 }
        NSLog("[MacMic] TCP stream resync, skipped \(i) bytes")
        tcpStreamBuf.removeFirst(min(i, tcpStreamBuf.count))
    }

    private func handleMediaPacket(data: Data) {
        let n = data.count
        // UDP Media Header: [ver(2BE)] [data_len(2BE)] [seq(2BE)] [ts(4BE)] [flag(1)] = 11 bytes
        guard n >= 11 else { return }
        
        let buf = [UInt8](data)
        
        // Check protocol version: 0x04, 0x00 (v4 in big-endian 2 bytes)
        guard buf[0] == 0x04 && buf[1] == 0x00 else { return }
        
        // Opus payload starts at byte 11
        let opusData = Data(buf[11..<n])
        
        if let monoPCM = self.opusDecoder?.decode(data: opusData) {
            self.audioEngine.writePCM(monoData: monoPCM)
            self.recordPacketStats(bytes: n)
        }
    }

    private func startPollLoop() {
        pollQueue.async { [weak self] in
            while let self = self, self.isRunning {
                Thread.sleep(forTimeInterval: 2.0)
                guard self.isRunning else { break }
                
                // 1. Send periodic 0x69 heartbeat over TCP to reset server 5s timer
                let heartbeatOk = self.sendPacketTCP(type: self.CMD_HEARTBEAT, payload: Data())
                if !heartbeatOk {
                    NSLog("[MacMic] Heartbeat 0x69 failed -> phone disconnected")
                    self.disconnect()
                    break
                }
                
                // 2. Keep UDP audio route alive by pinging phone's UDP port 8125
                self.sendUDPPing()
            }
        }
    }

    private func recordPacketStats(bytes: Int) {
        totalPktsCount += 1
        totalBytesCount += bytes

        let now = CACurrentMediaTime()
        if now - lastStatsUpdate >= 0.15 {
            lastStatsUpdate = now
            let pkts = totalPktsCount
            let b = totalBytesCount
            DispatchQueue.main.async {
                self.packetsReceived = pkts
                self.bytesReceived = b
            }
        }
    }

    public func disconnect() {
        guard isRunning || tcpSocketFd >= 0 || udpSocketFd >= 0 else { return }
        isRunning = false
        
        if tcpSocketFd >= 0 {
            // Attempt to send graceful stop capture (0x68)
            _ = sendPacketTCP(type: CMD_STOP_CAPTURE, payload: Data())
            close(tcpSocketFd)
            tcpSocketFd = -1
        }
        if udpSocketFd >= 0 {
            close(udpSocketFd)
            udpSocketFd = -1
        }
        DispatchQueue.main.async {
            self.audioEngine.stop()
            self.state = .disconnected
        }
    }
    
    // POSIX fd macros in Swift
    private func fdZero(_ set: inout fd_set) {
        let dummy = [Int32](repeating: 0, count: Int(MemoryLayout<fd_set>.size / MemoryLayout<Int32>.size))
        withUnsafeMutablePointer(to: &set) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: dummy.count) { intPtr in
                for i in 0..<dummy.count { intPtr[i] = 0 }
            }
        }
    }

    private func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let index = Int(fd / 32)
        let bit = Int32(1 << (fd % 32))
        withUnsafeMutablePointer(to: &set) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 32) { intPtr in
                intPtr[index] |= bit
            }
        }
    }

    private func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
        let index = Int(fd / 32)
        let bit = Int32(1 << (fd % 32))
        var isSet = false
        withUnsafeMutablePointer(to: &set) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 32) { intPtr in
                isSet = (intPtr[index] & bit) != 0
            }
        }
        return isSet
    }
}
