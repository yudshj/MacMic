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
    /// Only touched on `workerQueue`.
    private var tcpStreamBuf: [UInt8] = []

    public let audioEngine: AudioEngine
    private var opusDecoder: OpusDecoderWrapper?

    // Socket ownership: the connect worker (on `workerQueue`) creates and is the only code that
    // close()s the sockets. `tcpSocketFd` / `udpSocketFd` publish them so that `disconnect()`
    // (any thread) and the heartbeat loop can reach them; every access to these fields — and every
    // operation on the published fds from outside the worker — happens under `sockLock`, so an fd
    // is never used after the worker closed it (no fd-number reuse races).
    private let sockLock = NSLock()
    private var isRunning: Bool = false
    /// Bumped by every `disconnect()`/`connect()`; a worker or heartbeat loop whose generation is
    /// stale stops at its next check, so retries/backoff never outlive a user cancel.
    private var generation: UInt64 = 0
    private var tcpSocketFd: Int32 = -1
    /// Control socket on which `disconnect()` already sent 0x68 (avoids a duplicate on close).
    private var stopSentFd: Int32 = -1
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

    // Connect / retry budget. Worst case ≈ 3 × (4 s connect | 4 s connect + 3 s per handshake
    // step) + 1 s + 2 s backoff, but no new attempt starts once `connectTotalBudget` would be hit.
    private static let connectTimeout: TimeInterval = 4.0
    private static let handshakeReadTimeout: TimeInterval = 3.0
    private static let maxConnectAttempts = 3
    private static let retryBackoff: [TimeInterval] = [1.0, 2.0]
    private static let connectTotalBudget: TimeInterval = 20.0

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
        Self.installPerfHooksIfRequested(self)
        Self.installGracefulTermination(for: self)
    }

    // MARK: Graceful termination

    private static var terminationSources: [DispatchSourceSignal] = []
    private static var terminationObserver: NSObjectProtocol?

    /// SIGTERM/SIGINT/SIGHUP (kill, pkill, logout) and normal quit skip Cocoa teardown of the
    /// audio output, leaving a HAL client that died mid-IO (suspected cause of BlackHole wedges).
    /// Stop capture on the phone and stop/dispose the output unit first, bounded by a timeout.
    private static func installGracefulTermination(for client: MacMicClient) {
        guard terminationSources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { [weak client] in
                client?.shutdownForTermination()
                _exit(0)
            }
            src.resume()
            terminationSources.append(src)
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
        ) { [weak client] _ in client?.shutdownForTermination() }
    }

    /// Never blocks the audio thread; waits ≤ 1 s for the control queue to stop the output.
    /// `disconnect()` already armed SO_LINGER=0 on the control socket, so even if the worker has
    /// not closed it yet, the kernel close at `_exit` resets it (RST) right away.
    func shutdownForTermination() {
        disconnect()
        audioEngine.stopAndWait(timeout: 1.0)
    }

    public func connect(host: String, isUSB: Bool = false) {
        disconnect()
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = target
        self.isUSBMode = isUSB
        self.packetsReceived = 0
        self.bytesReceived = 0

        sockLock.lock()
        generation &+= 1
        isRunning = true
        let gen = generation
        sockLock.unlock()

        updateState(.connecting("正在连接 \(target):\(port)..."))

        let port = self.port
        workerQueue.async { [weak self] in
            self?.runConnectFlow(gen: gen, host: target, port: port, isUSB: isUSB)
        }
    }

    private func updateState(_ newState: ConnectionState) {
        DispatchQueue.main.async {
            self.state = newState
        }
    }

    // MARK: Generation / cancellation

    private func isCurrent(_ gen: UInt64) -> Bool {
        sockLock.lock(); defer { sockLock.unlock() }
        return isRunning && generation == gen
    }

    /// Marks a failed flow as stopped (only if no newer connect/disconnect superseded it).
    private func markStopped(_ gen: UInt64) {
        sockLock.lock()
        if generation == gen { isRunning = false }
        sockLock.unlock()
    }

    /// Sleeps in short slices; returns false as soon as `gen` is cancelled.
    private func sleepUnlessCancelled(_ seconds: TimeInterval, gen: UInt64) -> Bool {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            guard isCurrent(gen) else { return false }
            Thread.sleep(forTimeInterval: min(0.1, max(0, end - CACurrentMediaTime())))
        }
        return isCurrent(gen)
    }

    // MARK: Socket helpers

    private static func frame(type: UInt8, payload: Data = Data()) -> [UInt8] {
        let len = UInt32(payload.count)
        return [type, UInt8(len >> 24 & 0xFF), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)]
            + [UInt8](payload)
    }

    /// Abortive close: best-effort 0x68, shutdown(SHUT_RD), then SO_LINGER{1,0} + close() so the
    /// peer gets an RST right away instead of a FIN + TIME_WAIT teardown. This is a mitigation, not
    /// a cure: WoMic is a single-client server without an application-level read timeout, so a
    /// session whose 0x65 never arrives (silent packet loss, phone asleep) can linger as "已连接";
    /// an RST on that same lossy link may not arrive either. SHUT_WR is deliberately not used — it
    /// would put a FIN on the wire before the RST.
    private static func abortiveClose(_ fd: Int32, sendStop: Bool) {
        guard fd >= 0 else { return }
        armAbort(fd, sendStop: sendStop)
        close(fd)
    }

    /// Everything of `abortiveClose` except the close(): safe to call on an fd another thread owns.
    /// shutdown(SHUT_RD) sends nothing to the peer but wakes a worker blocked in
    /// poll()/select()/recv() on this fd (recv returns 0), which then closes it -> RST.
    private static func armAbort(_ fd: Int32, sendStop: Bool) {
        if sendStop {
            let stop = frame(type: 0x68)
            _ = stop.withUnsafeBufferPointer { send(fd, $0.baseAddress!, $0.count, MSG_DONTWAIT) }
        }
        shutdown(fd, SHUT_RD)
        var lg = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
    }

    private static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
    }

    private enum AttemptError: Error {
        case socketCreate(Int32)
        case badAddress
        case connectTimeout
        case connectRefused
        case connectUnreachable(Int32)
        case connectFailed(Int32)
        case sendFailed(step: String, errno: Int32)
        /// recv() == 0: the phone closed the connection (FIN).
        case peerClosed(step: String)
        case reset(step: String)
        case readTimeout(step: String)
        case readFailed(step: String, errno: Int32)
        case cancelled

        var isRetryable: Bool {
            switch self {
            case .socketCreate, .badAddress, .cancelled: return false
            default: return true
            }
        }

        var logDescription: String {
            switch self {
            case .socketCreate(let e): return "socket() failed: \(String(cString: strerror(e)))"
            case .badAddress: return "invalid IPv4 address"
            case .connectTimeout: return "TCP connect timeout"
            case .connectRefused: return "TCP connect refused"
            case .connectUnreachable(let e): return "TCP connect unreachable: \(String(cString: strerror(e)))"
            case .connectFailed(let e): return "TCP connect failed: \(String(cString: strerror(e)))"
            case .sendFailed(let s, let e): return "send \(s) failed: \(String(cString: strerror(e)))"
            case .peerClosed(let s): return "peer closed (EOF) waiting for \(s) reply"
            case .reset(let s): return "connection reset waiting for \(s) reply"
            case .readTimeout(let s): return "no \(s) reply within \(MacMicClient.handshakeReadTimeout)s"
            case .readFailed(let s, let e): return "recv \(s) failed: \(String(cString: strerror(e)))"
            case .cancelled: return "cancelled"
            }
        }
    }

    /// Waits for `events` on `fd` until `deadline`, in short slices so a cancel is noticed quickly.
    /// Returns revents, 0 on timeout; throws `.cancelled`.
    private func waitFor(_ fd: Int32, events: Int16, deadline: CFTimeInterval, gen: UInt64) throws -> Int16 {
        while true {
            guard isCurrent(gen) else { throw AttemptError.cancelled }
            let remaining = deadline - CACurrentMediaTime()
            if remaining <= 0 { return 0 }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&pfd, 1, Int32(min(100, max(1, remaining * 1000))))
            if r > 0 { return pfd.revents }
            if r < 0 && errno != EINTR { return Int16(POLLERR) }
        }
    }

    private func connectSocket(_ fd: Int32, addr: sockaddr_in, gen: UInt64) throws {
        var a = addr
        let r = withUnsafePointer(to: &a) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var err: Int32 = r == 0 ? 0 : errno
        if r != 0 && err == EINPROGRESS {
            let deadline = CACurrentMediaTime() + Self.connectTimeout
            let rev = try waitFor(fd, events: Int16(POLLOUT), deadline: deadline, gen: gen)
            if rev == 0 { throw AttemptError.connectTimeout }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            err = soErr
        }
        switch err {
        case 0: return
        case ETIMEDOUT: throw AttemptError.connectTimeout
        case ECONNREFUSED: throw AttemptError.connectRefused
        case ENETUNREACH, EHOSTUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL:
            throw AttemptError.connectUnreachable(err)
        default: throw AttemptError.connectFailed(err)
        }
    }

    /// Handshake-phase send on a non-blocking, worker-owned socket.
    private func sendAll(_ fd: Int32, _ bytes: [UInt8], step: String, gen: UInt64) throws {
        let deadline = CACurrentMediaTime() + Self.handshakeReadTimeout
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress! + off, bytes.count - off, 0) }
            if n > 0 { off += n; continue }
            let e = errno
            if n < 0 && (e == EAGAIN || e == EINTR) {
                if try waitFor(fd, events: Int16(POLLOUT), deadline: deadline, gen: gen) == 0 {
                    throw AttemptError.sendFailed(step: step, errno: ETIMEDOUT)
                }
                continue
            }
            if e == ECONNRESET || e == EPIPE { throw AttemptError.reset(step: step) }
            throw AttemptError.sendFailed(step: step, errno: e)
        }
    }

    private func recvExact(_ fd: Int32, _ count: Int, deadline: CFTimeInterval, step: String, gen: UInt64) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n > 0 { got += n; continue }
            if n == 0 { throw AttemptError.peerClosed(step: step) }
            let e = errno
            if e == EAGAIN || e == EINTR {
                if try waitFor(fd, events: Int16(POLLIN), deadline: deadline, gen: gen) == 0 {
                    throw AttemptError.readTimeout(step: step)
                }
                continue
            }
            if e == ECONNRESET { throw AttemptError.reset(step: step) }
            throw AttemptError.readFailed(step: step, errno: e)
        }
        return buf
    }

    /// Reads one control reply frame [cmd u8][len u32 BE][payload].
    private func readTCPResponse(_ fd: Int32, step: String, gen: UInt64) throws -> Data {
        let deadline = CACurrentMediaTime() + Self.handshakeReadTimeout
        let hdr = try recvExact(fd, 5, deadline: deadline, step: step, gen: gen)
        let len = Int(hdr[1]) << 24 | Int(hdr[2]) << 16 | Int(hdr[3]) << 8 | Int(hdr[4])
        guard len > 0 else { return Data() }
        return Data(try recvExact(fd, len, deadline: deadline, step: step, gen: gen))
    }

    private func request(_ fd: Int32, type: UInt8, payload: Data = Data(), gen: UInt64) throws {
        let step = String(format: "0x%02x", type)
        try sendAll(fd, Self.frame(type: type, payload: payload), step: step, gen: gen)
        _ = try readTCPResponse(fd, step: step, gen: gen)
    }

    // MARK: Connect flow

    /// One TCP connect + 0x65/0x66/0x67 handshake. On success returns the (published, blocking)
    /// control socket; on any failure the socket is closed abortively (RST) before throwing.
    private func performAttempt(gen: UInt64, addr: sockaddr_in) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AttemptError.socketCreate(errno) }

        sockLock.lock()
        guard isRunning && generation == gen else {
            sockLock.unlock()
            close(fd)
            throw AttemptError.cancelled
        }
        tcpSocketFd = fd
        sockLock.unlock()

        var connected = false
        do {
            var opt: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
            // Small control frames must go out immediately (so a 0x68 precedes our RST on the wire).
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, socklen_t(MemoryLayout<Int32>.size))
            Self.setNonBlocking(fd, true)

            try connectSocket(fd, addr: addr, gen: gen)
            connected = true

            // 0x65: Version check [proto_ver=4, client_maj=6, client_min=3, 0, 0, 0]
            try request(fd, type: CMD_CHECK_VERSION, payload: Data([0x04, 0x06, 0x03, 0x00, 0x00, 0x00]), gen: gen)

            // 0x66: Codec & client media UDP port
            // Payload: [codec=0x02, srIndex=0x02 (48k), clientMediaPort(4 BE)]
            var codecPayload = Data([0x02, 0x02])
            let clientMediaPort = UInt32(port)
            codecPayload.append(UInt8((clientMediaPort >> 24) & 0xFF))
            codecPayload.append(UInt8((clientMediaPort >> 16) & 0xFF))
            codecPayload.append(UInt8((clientMediaPort >> 8) & 0xFF))
            codecPayload.append(UInt8(clientMediaPort & 0xFF))
            try request(fd, type: CMD_SET_CODEC_PARAM, payload: codecPayload, gen: gen)

            // 0x67: Start audio capture
            try request(fd, type: CMD_START_CAPTURE, gen: gen)
        } catch {
            sockLock.lock()
            if tcpSocketFd == fd { tcpSocketFd = -1 }
            Self.abortiveClose(fd, sendStop: connected && stopSentFd != fd)
            if stopSentFd == fd { stopSentFd = -1 }
            sockLock.unlock()
            // A failure caused by a concurrent disconnect() (its shutdown wakes recv with EOF) is a cancel.
            if !isCurrent(gen) { throw AttemptError.cancelled }
            throw error
        }

        // Streaming phase uses blocking I/O (select + recv) as before.
        Self.setNonBlocking(fd, false)
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func runConnectFlow(gen: UInt64, host: String, port: Int, isUSB: Bool) {
        signal(SIGPIPE, SIG_IGN)
        tcpStreamBuf.removeAll(keepingCapacity: true)
        totalPktsCount = 0
        totalBytesCount = 0
        self.opusDecoder = OpusDecoderWrapper(sampleRate: 48000, channels: 1)

        var servAddr = sockaddr_in()
        servAddr.sin_family = sa_family_t(AF_INET)
        servAddr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &servAddr.sin_addr) == 1 else {
            return failFlow(gen: gen, error: .badAddress, host: host, port: port, attempts: 0)
        }
        self.serverSockAddr = servAddr

        // 1. TCP connect + handshake, with bounded retries. Every failed attempt has already been
        //    torn down with a best-effort 0x68 + RST before the next attempt starts.
        let started = CACurrentMediaTime()
        var attempt = 0
        var tFd: Int32 = -1
        while tFd < 0 {
            attempt += 1
            if attempt > 1 {
                let n = attempt, total = Self.maxConnectAttempts
                DispatchQueue.main.async {
                    let fmt = LocalizationManager.shared.t("status_retrying")
                    self.state = .connecting(String(format: fmt, n, total, "\(host):\(port)"))
                }
            }
            do {
                tFd = try performAttempt(gen: gen, addr: servAddr)
            } catch let e as AttemptError {
                NSLog("[MacMic] Connect attempt \(attempt)/\(Self.maxConnectAttempts) to \(host):\(port) failed: \(e.logDescription)")
                if case .cancelled = e { return }
                let backoff = attempt - 1 < Self.retryBackoff.count ? Self.retryBackoff[attempt - 1] : 0
                guard e.isRetryable, attempt < Self.maxConnectAttempts,
                      CACurrentMediaTime() - started + backoff < Self.connectTotalBudget else {
                    return failFlow(gen: gen, error: e, host: host, port: port, attempts: attempt)
                }
                guard sleepUnlessCancelled(backoff, gen: gen) else { return }
            } catch {
                return failFlow(gen: gen, error: .connectFailed(EIO), host: host, port: port, attempts: attempt)
            }
        }

        // 2. Create UDP Socket for Media
        var uFd = socket(AF_INET, SOCK_DGRAM, 0)
        if uFd >= 0 {
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
        }

        sockLock.lock()
        let stillCurrent = isRunning && generation == gen
        if stillCurrent && uFd >= 0 { udpSocketFd = uFd }
        sockLock.unlock()
        guard stillCurrent else {
            // Cancelled between handshake and streaming: disconnect() already sent 0x68/shutdown.
            if uFd >= 0 { close(uFd); uFd = -1 }
            releaseSockets(tcp: tFd, udp: -1)
            return
        }

        // Send initial trigger packet to punch UDP hole
        if uFd >= 0 { sendUDPPing(uFd) }

        // 3. Start Audio Engine (off the main thread; a wedged output driver must not freeze the UI)
        audioEngine.start { [weak self] ok in
            guard let self = self, !ok else { return }
            NSLog("[MacMic] Output device did not start within \(AudioEngine.startTimeout)s")
            guard self.isCurrent(gen) else { return }
            self.disconnect()
            DispatchQueue.main.async {
                self.state = .error("输出设备无响应（BlackHole 可能卡住），请重启音频服务：sudo killall coreaudiod")
            }
        }

        // 4. Start Keepalive Heartbeat Loop (TCP 0x69 every 2s + UDP Ping)
        startPollLoop(gen: gen)

        updateState(.streaming("麦克风工作中 (\(host))"))

        // 5. Receive Loop (Select on both TCP and UDP); returns once this generation is over.
        runReceiveLoop(gen: gen, tcpFd: tFd, udpFd: uFd, isUSB: isUSB)

        // 6. The worker owns the sockets: close them here on every exit path (RST on TCP).
        releaseSockets(tcp: tFd, udp: uFd)
    }

    /// Unpublishes and closes the worker's sockets (TCP abortively, with a best-effort 0x68).
    private func releaseSockets(tcp: Int32, udp: Int32) {
        sockLock.lock()
        if tcp >= 0 {
            if tcpSocketFd == tcp { tcpSocketFd = -1 }
            Self.abortiveClose(tcp, sendStop: stopSentFd != tcp)
            if stopSentFd == tcp { stopSentFd = -1 }
        }
        if udp >= 0 {
            if udpSocketFd == udp { udpSocketFd = -1 }
            close(udp)
        }
        sockLock.unlock()
    }

    private func failFlow(gen: UInt64, error: AttemptError, host: String, port: Int, attempts: Int) {
        guard isCurrent(gen) else { return }
        markStopped(gen)
        NSLog("[MacMic] Connect to \(host):\(port) gave up after \(attempts) attempt(s): \(error.logDescription)")
        let target = "\(host):\(port)"
        DispatchQueue.main.async {
            self.state = .error(Self.userMessage(for: error, target: target))
        }
    }

    /// Actionable, cause-specific error text (resolved on the main thread for the current language).
    private static func userMessage(for error: AttemptError, target: String) -> String {
        let l = LocalizationManager.shared
        func f(_ key: String, _ args: CVarArg...) -> String { String(format: l.t(key), arguments: args) }
        switch error {
        case .socketCreate(let e): return f("err_socket_create", String(cString: strerror(e)))
        case .badAddress: return f("err_bad_address", target)
        case .connectTimeout: return f("err_connect_timeout", target)
        case .connectRefused: return f("err_connect_refused", target)
        case .connectUnreachable: return f("err_connect_unreachable", target)
        case .connectFailed(let e): return f("err_connect_failed", target, String(cString: strerror(e)))
        case .peerClosed(let s), .reset(let s): return f("err_peer_closed", s)
        case .readTimeout(let s): return f("err_handshake_timeout", s)
        case .sendFailed(let s, let e), .readFailed(let s, let e):
            return f("err_handshake_io", s, String(cString: strerror(e)))
        case .cancelled: return ""
        }
    }

    private func sendUDPPing(_ fd: Int32) {
        guard fd >= 0 else { return }
        var trigger: [UInt8] = [0x00, 0x04, 0x00, 0x00]
        var target = serverSockAddr
        _ = withUnsafePointer(to: &target) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sPtr in
                sendto(fd, &trigger, trigger.count, 0, sPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func runReceiveLoop(gen: UInt64, tcpFd: Int32, udpFd: Int32, isUSB: Bool) {
        var tcpBuf = [UInt8](repeating: 0, count: 2048)
        var udpBuf = [UInt8](repeating: 0, count: 2048)

        while isCurrent(gen) {
            var readFds = fd_set()
            fdZero(&readFds)

            fdSet(tcpFd, &readFds)
            var maxFd = tcpFd
            if udpFd >= 0 {
                fdSet(udpFd, &readFds)
                maxFd = max(maxFd, udpFd)
            }

            var tv = timeval(tv_sec: 0, tv_usec: 500_000)
            let sel = select(maxFd + 1, &readFds, nil, nil, &tv)

            guard isCurrent(gen) else { break }

            if sel > 0 {
                // Check UDP (Media stream)
                if udpFd >= 0 && fdIsSet(udpFd, &readFds) {
                    var srcAddr = sockaddr_in()
                    var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sPtr in
                            recvfrom(udpFd, &udpBuf, udpBuf.count, 0, sPtr, &srcLen)
                        }
                    }
                    if n > 0 {
                        handleMediaPacket(data: Data(udpBuf[0..<n]))
                    }
                }

                // Check TCP (Control channel disconnect detection)
                if fdIsSet(tcpFd, &readFds) {
                    let n = recv(tcpFd, &tcpBuf, tcpBuf.count, 0)
                    if n <= 0 {
                        if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                        guard isCurrent(gen) else { break }
                        // Remote phone disconnected TCP channel
                        NSLog("[MacMic] Phone disconnected TCP control channel")
                        disconnect()
                        break
                    }
                    // USB (ADB) mode: the phone multiplexes audio onto the control TCP stream.
                    // Frames are [type(1)][len(4 BE)][len bytes]; type 0x04 carries a media packet
                    // with the same layout as a Wi-Fi UDP datagram (Opus payload at offset 11).
                    if isUSB {
                        tcpStreamBuf.append(contentsOf: tcpBuf[0..<n])
                        drainTCPFrames()
                    }
                }
            } else if sel < 0 && errno != EINTR {
                NSLog("[MacMic] select() failed: \(String(cString: strerror(errno)))")
                guard isCurrent(gen) else { break }
                disconnect()
                break
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

    private enum HeartbeatResult { case sent, skipped, failed }

    /// Heartbeat send under `sockLock` (never blocks: MSG_DONTWAIT on a 5-byte frame), so it can
    /// never race the worker's close().
    private func sendHeartbeat(gen: UInt64) -> HeartbeatResult {
        sockLock.lock(); defer { sockLock.unlock() }
        guard isRunning, generation == gen, tcpSocketFd >= 0 else { return .skipped }
        let hb = Self.frame(type: CMD_HEARTBEAT)
        let n = hb.withUnsafeBufferPointer { send(tcpSocketFd, $0.baseAddress!, $0.count, MSG_DONTWAIT) }
        if n == hb.count { return .sent }
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return .skipped }  // send buffer full: try next tick
        return .failed
    }

    private func startPollLoop(gen: UInt64) {
        pollQueue.async { [weak self] in
            while let self = self, self.isCurrent(gen) {
                guard self.sleepUnlessCancelled(2.0, gen: gen) else { break }

                // 1. Send periodic 0x69 heartbeat over TCP to reset server 5s timer
                switch self.sendHeartbeat(gen: gen) {
                case .failed:
                    NSLog("[MacMic] Heartbeat 0x69 failed -> phone disconnected")
                    if self.isCurrent(gen) { self.disconnect() }
                    return
                case .skipped, .sent:
                    break
                }

                // 2. Keep UDP audio route alive by pinging phone's UDP port 8125
                self.sockLock.lock()
                if self.generation == gen && self.udpSocketFd >= 0 { self.sendUDPPing(self.udpSocketFd) }
                self.sockLock.unlock()
            }
        }
    }

    private func recordPacketStats(bytes: Int) {
        totalPktsCount += 1
        totalBytesCount += bytes

        let now = CACurrentMediaTime()
        if now - lastStatsUpdate >= 0.5 {
            lastStatsUpdate = now
            let pkts = totalPktsCount
            let b = totalBytesCount
            DispatchQueue.main.async {
                self.packetsReceived = pkts
                self.bytesReceived = b
            }
        }
    }

    /// Stops the current session (or cancels an in-flight connect/retry). Safe from any thread and
    /// never blocks: it sends a best-effort 0x68, shutdown()s the control socket and arms
    /// SO_LINGER=0; the worker then closes it, which resets (RST) the connection on the phone.
    public func disconnect() {
        sockLock.lock()
        let wasActive = isRunning || tcpSocketFd >= 0 || udpSocketFd >= 0
        isRunning = false
        generation &+= 1
        if tcpSocketFd >= 0 && stopSentFd != tcpSocketFd {
            Self.armAbort(tcpSocketFd, sendStop: true)
            stopSentFd = tcpSocketFd
        }
        sockLock.unlock()
        guard wasActive else { return }

        audioEngine.stop()
        DispatchQueue.main.async {
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

// MARK: - Perf-measurement hooks (debug only, inert unless launched with -macmic_perf_control YES)

import AppKit

/// Appends a line to /tmp/macmic_perf.log, only when launched with -macmic_perf_control YES
/// (NSLog payloads are redacted as <private> in the unified log).
let macmicPerfEnabled = UserDefaults.standard.bool(forKey: "macmic_perf_control")
func macmicPerfLog(_ message: @autoclosure () -> String) {
    guard macmicPerfEnabled else { return }
    let line = "\(Date()) pid=\(getpid()) \(message())\n"
    if let h = FileHandle(forWritingAtPath: "/tmp/macmic_perf.log") ?? {
        FileManager.default.createFile(atPath: "/tmp/macmic_perf.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/macmic_perf.log") }() {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    }
}

extension MacMicClient {
    /// Lets scripted CPU measurements drive the app without Accessibility:
    ///   launch args:  -macmic_perf_control YES  [-macmic_perf_autoconnect_usb YES] [-macmic_perf_close_window YES]
    ///   distributed notification "com.macmic.perf" with object "connect" | "disconnect" | "hide" | "show" | "stats"
    /// Every action is logged with NSLog("[MacMicPerf] ...").
    static func installPerfHooksIfRequested(_ client: MacMicClient) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "macmic_perf_control") else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.macmic.perf"), object: nil, queue: .main) { note in
            client.perfAction((note.object as? String) ?? "")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if d.bool(forKey: "macmic_perf_close_window") { client.perfAction("hide") }
            if d.bool(forKey: "macmic_perf_autoconnect_usb") { client.perfAction("connect") }
        }
    }

    fileprivate func perfAction(_ action: String) {
        switch action {
        case "connect": connect(host: "127.0.0.1", isUSB: true)
        case "disconnect": disconnect()
        case "hide": AppDelegate.mainWindow?.performClose(nil)
        case "show": AppDelegate.shared?.showMainWindow()
        case "stats": break
        default: return
        }
        let dn = audioEngine.denoiser
        let r = audioEngine.ringStats
        macmicPerfLog("action=\(action) state=\(state) denoise=\(dn.effectiveDescription) latency=\(dn.activeLatency) "
            + "underruns=\(r.underruns) trims=\(r.trims) buffered=\(r.buffered) pkts=\(packetsReceived)")
    }
}
