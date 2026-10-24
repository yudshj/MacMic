import Foundation
import AudioToolbox
import CoreAudio
import QuartzCore

/// Clean, zero-latency DSP processor for microphone level calibration & clarity
public final class VoiceDSPProcessor {
    // 80Hz Butterworth High-Pass Filter Coefficients (for 48000Hz, Q = 0.707)
    private let hp_b0: Float = 0.99262144
    private let hp_b1: Float = -1.98524288
    private let hp_b2: Float = 0.99262144
    private let hp_a1: Float = -1.98518845
    private let hp_a2: Float = 0.98529731
    private var hp_x1_L: Float = 0.0, hp_x2_L: Float = 0.0, hp_y1_L: Float = 0.0, hp_y2_L: Float = 0.0
    private var hp_x1_R: Float = 0.0, hp_x2_R: Float = 0.0, hp_y1_R: Float = 0.0, hp_y2_R: Float = 0.0

    // 3.2kHz Vocal Presence & Clarity Peaking Filter (+3.0dB, Q = 0.8)
    private let eq_b0: Float = 1.07168925
    private let eq_b1: Float = -1.51271430
    private let eq_b2: Float = 0.58418270
    private let eq_a1: Float = -1.51271430
    private let eq_a2: Float = 0.65587195
    private var eq_x1_L: Float = 0.0, eq_x2_L: Float = 0.0, eq_y1_L: Float = 0.0, eq_y2_L: Float = 0.0
    private var eq_x1_R: Float = 0.0, eq_x2_R: Float = 0.0, eq_y1_R: Float = 0.0, eq_y2_R: Float = 0.0

    // Standard PC Microphone Sensitivity Calibration Factor (+12dB = 4.0x)
    // Mobile mic ADCs capture raw telephony-level signals (~ -26dBFS at desk distance).
    // This baseline calibration brings 100% gain to standard broadcast/meeting level (-8dBFS to -12dBFS).
    private let baselineCalibration: Float = 4.0

    public func reset() {
        hp_x1_L = 0; hp_x2_L = 0; hp_y1_L = 0; hp_y2_L = 0
        hp_x1_R = 0; hp_x2_R = 0; hp_y1_R = 0; hp_y2_R = 0
        eq_x1_L = 0; eq_x2_L = 0; eq_y1_L = 0; eq_y2_L = 0
        eq_x1_R = 0; eq_x2_R = 0; eq_y1_R = 0; eq_y2_R = 0
    }

    public func process(stereoBuffer: UnsafeMutablePointer<Int16>, sampleCount: Int, userGain: Float, isMuted: Bool) -> (peak: Float, rms: Float) {
        if isMuted {
            for i in 0..<sampleCount {
                stereoBuffer[i] = 0
            }
            return (0.0, 0.0)
        }

        let effectiveGain = userGain * baselineCalibration
        var outSumSquares: Float = 0.0
        var maxPeak: Float = 0.0

        for i in stride(from: 0, to: sampleCount, by: 2) {
            var sL = Float(stereoBuffer[i]) / 32768.0
            var sR = Float(stereoBuffer[i + 1]) / 32768.0

            // 1. 80Hz Low-Cut (High-Pass) to remove desk rumble & mud
            let yL1 = hp_b0 * sL + hp_b1 * hp_x1_L + hp_b2 * hp_x2_L - hp_a1 * hp_y1_L - hp_a2 * hp_y2_L
            hp_x2_L = hp_x1_L; hp_x1_L = sL; hp_y2_L = hp_y1_L; hp_y1_L = yL1; sL = yL1

            let yR1 = hp_b0 * sR + hp_b1 * hp_x1_R + hp_b2 * hp_x2_R - hp_a1 * hp_y1_R - hp_a2 * hp_y2_R
            hp_x2_R = hp_x1_R; hp_x1_R = sR; hp_y2_R = hp_y1_R; hp_y1_R = yR1; sR = yR1

            // 2. 3.2kHz Voice Clarity & Consonant Presence
            let yL2 = eq_b0 * sL + eq_b1 * eq_x1_L + eq_b2 * eq_x2_L - eq_a1 * eq_y1_L - eq_a2 * eq_y2_L
            eq_x2_L = eq_x1_L; eq_x1_L = sL; eq_y2_L = eq_y1_L; eq_y1_L = yL2; sL = yL2

            let yR2 = eq_b0 * sR + eq_b1 * eq_x1_R + eq_b2 * eq_x2_R - eq_a1 * eq_y1_R - eq_a2 * eq_y2_R
            eq_x2_R = eq_x1_R; eq_x1_R = sR; eq_y2_R = eq_y1_R; eq_y1_R = yR2; sR = yR2

            // 3. Apply Calibrated Gain
            sL *= effectiveGain
            sR *= effectiveGain

            // 4. Soft-Knee Studio Limiter (prevents harsh digital clipping on loud speech)
            sL = softLimit(sL)
            sR = softLimit(sR)

            let outValL = max(-32768.0, min(32767.0, sL * 32767.0))
            let outValR = max(-32768.0, min(32767.0, sR * 32767.0))
            stereoBuffer[i] = Int16(outValL)
            stereoBuffer[i + 1] = Int16(outValR)

            let mag = max(abs(sL), abs(sR))
            if mag > maxPeak { maxPeak = mag }
            outSumSquares += sL * sL + sR * sR
        }

        let outRMS = sqrt(outSumSquares / Float(max(1, sampleCount)))
        return (maxPeak, outRMS)
    }

    @inline(__always)
    private func softLimit(_ x: Float) -> Float {
        if x > 0.85 {
            let excess = x - 0.85
            return 0.85 + 0.15 * tanh(excess / 0.15)
        } else if x < -0.85 {
            let excess = x + 0.85
            return -0.85 + 0.15 * tanh(excess / 0.15)
        }
        return x
    }
}

public final class AudioEngine: ObservableObject {
    /// Meter values, normalised 0...1 over -60...0 dBFS (see `AudioEngine.meterFloorDB`).
    /// Ballistics are computed on the audio thread; published at ~15 Hz.
    @Published public var vuLevel: Float = 0.0
    @Published public var vuPeak: Float = 0.0
    public static let meterFloorDB: Float = -60
    @Published public var gain: Float = 1.0 // 0.0 to 2.0 (1.0 = 100% standard calibrated volume)
    @Published public var isMuted: Bool = false

    public let dsp = VoiceDSPProcessor()

    /// Speech denoiser applied to the mono phone stream before it is queued for playback.
    public let denoiser = DenoiseProcessor()

    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private let bufferCount = 4
    // 20ms at 48000Hz Stereo (2 ch * 2 bytes * 960 frames = 3840 bytes)
    private let bufferSize: UInt32 = 960 * 2 * 2
    private var isRunning = false
    private var lastVUUpdate: CFTimeInterval = 0
    // Meter ballistics state (audio thread only)
    private var meterLevelDB: Float = -100
    private var meterPeakDB: Float = -100
    private var meterPeakHoldUntil: CFTimeInterval = 0

    // Jitter buffer: preallocated ring of interleaved stereo Int16 frames.
    // Writer = network/decoder worker thread, reader = AudioQueue callback.
    private let ring = StereoRingBuffer(capacityFrames: 48000)   // 1 s
    /// Start (and re-start after an underrun) only once this much audio is buffered.
    private let primeFrames = 960 * 2                            // 40 ms
    /// If network bursts push buffered audio above this, trim the oldest audio...
    private let maxBufferedFrames = 48000 / 5                    // 200 ms
    /// ...down to this, so latency can't creep up. Trims are rare single events instead of
    /// the old "drop 10 packets whenever > 50 are queued" behaviour.
    private let trimToFrames = 48000 * 8 / 100                   // 80 ms

    // Scratch buffers for the worker thread (grown on demand, reused across packets).
    private var monoFloat: [Float] = []
    private var stereoScratch: [Int16] = []

    public var currentDevice: AudioDevice?
    public var ringStats: (underruns: Int, trims: Int, buffered: Int) { (ring.underruns, ring.trims, ring.bufferedFrames) }

    public init() {
        self.currentDevice = AudioDeviceManager.getDefaultDevice()
    }

    deinit {
        stopSync()
    }

    /// AudioQueue start/stop talk to coreaudiod synchronously and can block indefinitely if a
    /// HAL driver wedges (observed with BlackHole: AudioQueueStart never returned). They run on
    /// this queue so the UI never freezes; `start` reports a hang through its completion.
    private let controlQueue = DispatchQueue(label: "com.macmic.audio.control", qos: .userInitiated)
    public static let startTimeout: TimeInterval = 3

    /// Starts playback asynchronously. `completion(true)` once running, `completion(false)` if
    /// the output device did not respond within `startTimeout` (called on the main queue, once).
    public func start(device: AudioDevice? = nil, completion: ((Bool) -> Void)? = nil) {
        let lock = NSLock()
        var reported = false
        let report: (Bool) -> Void = { ok in
            lock.lock(); let first = !reported; reported = true; lock.unlock()
            if first, let completion = completion { DispatchQueue.main.async { completion(ok) } }
        }
        controlQueue.async { [weak self] in
            self?.startSync(device: device)
            report(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { report(false) }
    }

    public func stop() {
        controlQueue.async { [weak self] in self?.stopSync() }
    }
    @discardableResult
    public func stopAndWait(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        controlQueue.async { [weak self] in self?.stopSync(); done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private func startSync(device: AudioDevice? = nil) {
        stopSync()
        dsp.reset()
        ring.reset(primeFrames: primeFrames)
        denoiser.requestReset()

        if let dev = device {
            self.currentDevice = dev
        }

        // Ensure macOS input volume is set to 100% so system apps (e.g. WeChat) don't attenuate the virtual mic
        DispatchQueue.global(qos: .utility).async {
            let script = "set volume input volume 100"
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2, // Stereo for full BlackHole and macOS compatibility
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let callback: AudioQueueOutputCallback = { userData, queue, buffer in
            guard let userData = userData else { return }
            let engine = Unmanaged<AudioEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.handleAudioQueueOutput(queue: queue, buffer: buffer)
        }

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = AudioQueueNewOutput(&format, callback, selfPtr, nil, nil, 0, &audioQueue)

        guard status == noErr, let queue = audioQueue else {
            return
        }

        if let dev = self.currentDevice, !dev.uid.isEmpty {
            var uidCF = dev.uid as CFString
            _ = withUnsafePointer(to: &uidCF) { ptr in
                AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, ptr, UInt32(MemoryLayout<CFString>.size))
            }
        }

        buffers.removeAll()
        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, bufferSize, &buffer)
            if let buf = buffer {
                buf.pointee.mAudioDataByteSize = bufferSize
                memset(buf.pointee.mAudioData, 0, Int(bufferSize))
                AudioQueueEnqueueBuffer(queue, buf, 0, nil)
                buffers.append(buf)
            }
        }

        AudioQueueStart(queue, nil)
        isRunning = true
    }

    private func stopSync() {
        isRunning = false
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        buffers.removeAll()
        ring.reset(primeFrames: primeFrames)
        meterLevelDB = -100; meterPeakDB = -100
        DispatchQueue.main.async {
            self.vuLevel = 0.0
            self.vuPeak = 0.0
        }
    }

    /// Called on the network/decoder worker thread with one decoded mono Int16 packet.
    public func writePCM(monoData: Data) {
        guard isRunning else { return }
        let sampleCount = monoData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        if monoFloat.count < sampleCount { monoFloat = [Float](repeating: 0, count: sampleCount) }
        if stereoScratch.count < sampleCount * 2 { stereoScratch = [Int16](repeating: 0, count: sampleCount * 2) }

        monoFloat.withUnsafeMutableBufferPointer { mono in
            let m = mono.baseAddress!
            monoData.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleCount { m[i] = Float(src[i]) }
            }

            // Denoise (no-op and zero-latency while disabled). Runs here, not on the render thread.
            denoiser.process(m, count: sampleCount)

            // Mono → stereo Int16 (L = R)
            stereoScratch.withUnsafeMutableBufferPointer { st in
                let d = st.baseAddress!
                for i in 0..<sampleCount {
                    let v = Int16(max(-32768, min(32767, m[i].rounded())))
                    d[i * 2] = v
                    d[i * 2 + 1] = v
                }
                ring.write(d, frames: sampleCount, maxBufferedFrames: maxBufferedFrames, trimToFrames: trimToFrames)
            }
        }
    }

    private func handleAudioQueueOutput(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        guard isRunning else {
            buffer.pointee.mAudioDataByteSize = bufferSize
            memset(buffer.pointee.mAudioData, 0, Int(bufferSize))
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        let framesWanted = Int(bufferSize) / 4
        let dest = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        // Reads whatever is available (0 while priming), zero-fills the rest.
        let framesRead = ring.read(dest, frames: framesWanted, primeFrames: primeFrames)
        let filledBytes = framesRead * 4

        if filledBytes < Int(bufferSize) {
            memset(buffer.pointee.mAudioData.advanced(by: filledBytes), 0, Int(bufferSize) - filledBytes)
        }
        buffer.pointee.mAudioDataByteSize = bufferSize

        // Apply VoiceDSPProcessor (Low-Cut, Clarity EQ, Calibrated Gain, Soft Limiter)
        let samples = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        let totalSamples = Int(bufferSize) / MemoryLayout<Int16>.size

        let (peak, rms) = dsp.process(
            stereoBuffer: samples,
            sampleCount: totalSamples,
            userGain: self.gain,
            isMuted: self.isMuted
        )
        updateMeter(peak: peak, rms: rms, bufferSeconds: Float(totalSamples / 2) / 48000)

        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }
}

extension AudioEngine {
    /// PPM-style ballistics: instant attack, 24 dB/s release for the level bar;
    /// the peak marker holds for 1 s, then falls at 12 dB/s.
    fileprivate func updateMeter(peak: Float, rms: Float, bufferSeconds: Float) {
        let rmsDB = rms > 0 ? 20 * log10(rms) : -100
        let peakDB = peak > 0 ? 20 * log10(peak) : -100
        meterLevelDB = max(rmsDB, meterLevelDB - 24 * bufferSeconds)

        let now = CACurrentMediaTime()
        if peakDB >= meterPeakDB {
            meterPeakDB = peakDB
            meterPeakHoldUntil = now + 1.0
        } else if now > meterPeakHoldUntil {
            meterPeakDB = max(peakDB, meterPeakDB - 12 * bufferSeconds)
        }

        guard now - lastVUUpdate >= 0.066 else { return }   // ~15 Hz is plenty for a meter
        lastVUUpdate = now
        let floor = Self.meterFloorDB
        let level = max(0, min(1, (meterLevelDB - floor) / -floor))
        let peakNorm = max(0, min(1, (meterPeakDB - floor) / -floor))
        DispatchQueue.main.async {
            self.vuLevel = level
            self.vuPeak = peakNorm
        }
    }
}

/// Preallocated single-producer / single-consumer ring of interleaved stereo Int16 frames.
/// Guarded by an os_unfair_lock held only for the memcpy (no allocation, no Data churn).
final class StereoRingBuffer {
    private let capacity: Int            // frames
    private let storage: UnsafeMutablePointer<Int16>
    private var readPos = 0              // frames
    private var count = 0                // frames buffered
    private var primed = false
    private var lock = os_unfair_lock()

    /// Diagnostics.
    private(set) var underruns = 0
    private(set) var trims = 0

    init(capacityFrames: Int) {
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    func reset(primeFrames: Int) {
        os_unfair_lock_lock(&lock)
        readPos = 0; count = 0; primed = false
        os_unfair_lock_unlock(&lock)
    }

    var bufferedFrames: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    func write(_ src: UnsafePointer<Int16>, frames: Int, maxBufferedFrames: Int, trimToFrames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var frames = frames
        var src = src
        if frames > capacity {                       // absurdly large packet: keep the newest part
            src = src.advanced(by: (frames - capacity) * 2)
            frames = capacity
        }
        // Latency cap: drop the oldest audio once, down to the trim target.
        if count + frames > maxBufferedFrames {
            let drop = min(count, count + frames - trimToFrames)
            if drop > 0 {
                readPos = (readPos + drop) % capacity
                count -= drop
                trims += 1
            }
        }
        let writePos = (readPos + count) % capacity
        let first = min(frames, capacity - writePos)
        (storage + writePos * 2).update(from: src, count: first * 2)
        if first < frames {
            storage.update(from: src + first * 2, count: (frames - first) * 2)
        }
        count += frames
    }

    /// Returns frames copied into `dst` (≤ frames). Holds output while (re)priming.
    func read(_ dst: UnsafeMutablePointer<Int16>, frames: Int, primeFrames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if !primed {
            guard count >= primeFrames else { return 0 }
            primed = true
        }
        let n = min(frames, count)
        let first = min(n, capacity - readPos)
        dst.update(from: storage + readPos * 2, count: first * 2)
        if first < n {
            (dst + first * 2).update(from: storage, count: (n - first) * 2)
        }
        readPos = (readPos + n) % capacity
        count -= n
        if n < frames {
            // Underrun: wait for a fresh cushion instead of crackling packet-by-packet.
            primed = false
            underruns += 1
        }
        return n
    }
}
