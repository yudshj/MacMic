import Foundation
import AudioToolbox
import CRNNoise

// MARK: - Public configuration

public enum DenoiseMode: String, CaseIterable, Identifiable {
    /// xiph RNNoise (BSD-3, "little" model): 20 ms latency, ~2% of one core.
    case rnnoise
    /// Apple's AUSoundIsolation (FaceTime "Voice Isolation"): ~56 ms latency, runs via CoreML.
    case appleVoiceIsolation

    public var id: String { rawValue }
}

public struct DenoiseConfig: Equatable {
    public var enabled: Bool
    public var mode: DenoiseMode
    /// 0...1. Wet/dry mix of the denoised signal against the latency-aligned original.
    public var strength: Float

    public init(enabled: Bool = false, mode: DenoiseMode = .rnnoise, strength: Float = 1.0) {
        self.enabled = enabled
        self.mode = mode
        self.strength = strength
    }
}

// MARK: - Engines (mono Float, int16 scale, fixed 480-sample blocks)

/// A denoise engine consumes and produces exactly `DenoiseProcessor.blockSize` samples per call.
/// Output is delayed by `latency` samples relative to input.
protocol DenoiseEngine: AnyObject {
    var latency: Int { get }
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>)
}

final class PassthroughEngine: DenoiseEngine {
    let latency = 0
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        output.update(from: input, count: DenoiseProcessor.blockSize)
    }
}

final class RNNoiseEngine: DenoiseEngine {
    private let state: OpaquePointer
    /// Measured: output lags input by exactly 960 samples (20 ms). The 20 ms analysis window
    /// with a 10 ms hop delays by one frame, plus one frame of internal buffering.
    let latency = 960

    init?() {
        guard Int(rnnoise_get_frame_size()) == DenoiseProcessor.blockSize,
              let st = rnnoise_create(nil) else { return nil }
        state = st
    }

    deinit { rnnoise_destroy(state) }

    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        // RNNoise expects samples in int16 range (±32768), which is what we carry.
        _ = rnnoise_process_frame(state, output, input)
    }
}

final class AppleVoiceIsolationEngine: DenoiseEngine {
    private var unit: AudioUnit
    private(set) var latency: Int = 0
    /// Input handed to the AU's render callback (scaled to ±1).
    fileprivate let scratchIn = UnsafeMutablePointer<Float>.allocate(capacity: DenoiseProcessor.blockSize)
    private let scratchOut = UnsafeMutablePointer<Float>.allocate(capacity: DenoiseProcessor.blockSize)
    private var sampleTime: Float64 = 0

    /// kAudioUnitSubType_AUSoundIsolation ('vois', macOS 13+). Raw value so we still build for macOS 12.
    private static let subtype: OSType = 0x766F_6973
    private static let paramWetDryMix: AudioUnitParameterID = 0  // kAUSoundIsolationParam_WetDryMixPercent
    private static let paramSoundType: AudioUnitParameterID = 1  // kAUSoundIsolationParam_SoundToIsolate
    private static let soundTypeVoice: AudioUnitParameterValue = 1  // kAUSoundIsolationSoundType_Voice

    static var isAvailable: Bool {
        var desc = componentDescription
        return AudioComponentFindNext(nil, &desc) != nil
    }

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
    }

    init?() {
        var desc = Self.componentDescription
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(comp, &instance) == noErr, let au = instance else { return nil }
        unit = au

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxFrames = UInt32(DenoiseProcessor.blockSize)
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frames, ioData in
                guard let ioData = ioData else { return kAudio_ParamError }
                let engine = Unmanaged<AppleVoiceIsolationEngine>.fromOpaque(refCon).takeUnretainedValue()
                let abl = UnsafeMutableAudioBufferListPointer(ioData)
                guard let dst = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
                dst.update(from: engine.scratchIn, count: min(Int(frames), DenoiseProcessor.blockSize))
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        let ok = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize) == noErr
            && AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, asbdSize) == noErr
            && AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4) == noErr
            && AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
        // We do our own latency-aligned wet/dry mix, so the AU always runs fully wet.
        _ = AudioUnitSetParameter(au, Self.paramWetDryMix, kAudioUnitScope_Global, 0, 100, 0)
        _ = AudioUnitSetParameter(au, Self.paramSoundType, kAudioUnitScope_Global, 0, Self.soundTypeVoice, 0)

        guard ok, AudioUnitInitialize(au) == noErr else {
            AudioComponentInstanceDispose(au)
            scratchIn.deallocate(); scratchOut.deallocate()
            return nil
        }

        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size) == noErr {
            // Truncate: 56.35 ms reports as 2704.8 samples, measured alignment is 2704.
            latency = Int(seconds * 48000)
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        scratchIn.deallocate()
        scratchOut.deallocate()
    }

    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>) {
        let n = DenoiseProcessor.blockSize
        for i in 0..<n { scratchIn[i] = input[i] * (1.0 / 32768.0) }

        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: scratchOut))
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        ts.mSampleTime = sampleTime
        sampleTime += Float64(n)
        var flags = AudioUnitRenderActionFlags()

        if AudioUnitRender(unit, &flags, &ts, 0, UInt32(n), &abl) == noErr,
           let data = abl.mBuffers.mData?.assumingMemoryBound(to: Float.self) {
            for i in 0..<n { output[i] = data[i] * 32768.0 }
        } else {
            output.initialize(repeating: 0, count: n)
        }
    }
}

// MARK: - Latency-aligned dry path

/// Fixed delay line that delays the original signal by exactly the engine latency,
/// so the wet/dry mix sums time-aligned signals (no comb filtering).
final class DelayLine {
    private var buffer: [Float]
    private var index = 0
    let delay: Int

    init(delay: Int) {
        self.delay = delay
        buffer = [Float](repeating: 0, count: max(delay, 1))
    }

    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int) {
        guard delay > 0 else {
            output.update(from: input, count: count)
            return
        }
        buffer.withUnsafeMutableBufferPointer { buf in
            for i in 0..<count {
                output[i] = buf[index]
                buf[index] = input[i]
                index += 1
                if index == delay { index = 0 }
            }
        }
    }
}

/// One complete processing path: engine + matching dry delay.
final class DenoisePath {
    let engine: DenoiseEngine
    let dry: DelayLine
    let mode: DenoiseMode?   // nil = passthrough

    init(engine: DenoiseEngine, mode: DenoiseMode?) {
        self.engine = engine
        self.mode = mode
        self.dry = DelayLine(delay: engine.latency)
    }

    var latency: Int { engine.latency }
}

// MARK: - Processor

/// Real-time speech denoiser for the phone stream.
///
/// Runs on the network/decoder worker thread (never the AudioQueue render thread).
/// Works on mono Float samples in int16 range, in fixed 480-sample (10 ms) blocks.
/// Arbitrary input sizes are supported through small FIFOs; for the usual 20 ms
/// Opus frames (960 samples) no extra buffering latency is added.
public final class DenoiseProcessor {
    public static let blockSize = 480

    private var requested = DenoiseConfig()
    private var configLock = os_unfair_lock()

    private var path: DenoisePath?          // nil while fully bypassed
    private var activeEnabled = false
    private var activeMode: DenoiseMode = .rnnoise
    private var currentStrength: Float = 1.0
    /// Old path kept alive for one block to crossfade into the new one.
    private var fadingOut: DenoisePath?
    /// Wet/dry strength the old path was playing at when the switch happened.
    private var fadingOutStrength: Float = 0

    private var inFifo: [Float] = []
    private var outFifo: [Float] = []
    private var blockIn = [Float](repeating: 0, count: blockSize)
    private var wet = [Float](repeating: 0, count: blockSize)
    private var dry = [Float](repeating: 0, count: blockSize)
    private var oldWet = [Float](repeating: 0, count: blockSize)
    private var oldDry = [Float](repeating: 0, count: blockSize)

    /// Latency added by the active path (samples @ 48 kHz), for display.
    public private(set) var activeLatency: Int = 0
    /// Set when the requested engine could not be created (e.g. AUSoundIsolation missing).
    public private(set) var lastError: String?

    public init() {
        inFifo.reserveCapacity(4096)
        outFifo.reserveCapacity(4096)
    }

    public static var isAppleVoiceIsolationAvailable: Bool { AppleVoiceIsolationEngine.isAvailable }

    /// Thread-safe; picked up at the start of the next `process` call.
    public func setConfig(_ config: DenoiseConfig) {
        os_unfair_lock_lock(&configLock)
        requested = config
        os_unfair_lock_unlock(&configLock)
    }

    private var resetRequested = false

    /// Thread-safe. Call on (re)connect: engine state is dropped before the next block
    /// so a new stream starts clean (the reset itself runs on the processing thread).
    public func requestReset() {
        os_unfair_lock_lock(&configLock)
        resetRequested = true
        os_unfair_lock_unlock(&configLock)
    }

    private func performReset() {
        path = nil
        fadingOut = nil
        activeEnabled = false
        activeLatency = 0
        inFifo.removeAll(keepingCapacity: true)
        outFifo.removeAll(keepingCapacity: true)
    }

    /// Denoise `count` mono samples in place.
    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&configLock)
        let cfg = requested
        let doReset = resetRequested
        resetRequested = false
        os_unfair_lock_unlock(&configLock)

        if doReset { performReset() }
        applyConfigIfNeeded(cfg)

        // Fully bypassed: zero latency, zero cost.
        if path == nil && fadingOut == nil && inFifo.isEmpty && outFifo.isEmpty { return }

        let targetStrength = cfg.enabled ? max(0, min(1, cfg.strength)) : 0
        inFifo.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        let n = Self.blockSize
        while inFifo.count >= n {
            for i in 0..<n { blockIn[i] = inFifo[i] }
            inFifo.removeFirst(n)
            processBlock(targetStrength: targetStrength)
            outFifo.append(contentsOf: wet)
        }

        // Odd frame sizes: grow latency once (zero-pad) instead of glitching every packet.
        if outFifo.count < count {
            outFifo.insert(contentsOf: repeatElement(0, count: count - outFifo.count), at: 0)
        }
        for i in 0..<count { samples[i] = outFifo[i] }
        outFifo.removeFirst(count)

        // Once disabled and drained, drop back to bypass.
        if !cfg.enabled, path?.mode == nil, fadingOut == nil, inFifo.isEmpty, outFifo.isEmpty {
            path = nil
            activeLatency = 0
        }
    }

    // MARK: Internals

    private func applyConfigIfNeeded(_ cfg: DenoiseConfig) {
        let changed = cfg.enabled != activeEnabled || (cfg.enabled && cfg.mode != activeMode)
        guard changed else { return }

        let newPath: DenoisePath
        if cfg.enabled, let engine = makeEngine(cfg.mode) {
            newPath = DenoisePath(engine: engine, mode: cfg.mode)
            lastError = nil
        } else {
            if cfg.enabled { lastError = "\(cfg.mode.rawValue) unavailable" }
            newPath = DenoisePath(engine: PassthroughEngine(), mode: nil)
        }

        // Crossfade from whatever was playing (an active path, or the raw signal).
        fadingOut = path ?? DenoisePath(engine: PassthroughEngine(), mode: nil)
        fadingOutStrength = (fadingOut?.mode == nil) ? 0 : currentStrength
        path = newPath
        activeEnabled = cfg.enabled
        activeMode = cfg.mode
        activeLatency = newPath.latency
        // A new path starts fully wet at the requested strength; the crossfade hides the switch.
        currentStrength = cfg.enabled ? max(0, min(1, cfg.strength)) : 0
    }

    private func makeEngine(_ mode: DenoiseMode) -> DenoiseEngine? {
        switch mode {
        case .rnnoise: return RNNoiseEngine()
        case .appleVoiceIsolation: return AppleVoiceIsolationEngine()
        }
    }

    /// Processes `blockIn` → `wet` (final mixed output for this block).
    private func processBlock(targetStrength: Float) {
        guard let path = path else { return }
        let n = Self.blockSize

        runPath(path, wet: &wet, dry: &dry)

        // Strength ramps linearly across the block to avoid zipper noise.
        let s0 = currentStrength
        let s1 = path.mode == nil ? 0 : targetStrength
        let step = (s1 - s0) / Float(n)
        for i in 0..<n {
            let s = s0 + step * Float(i + 1)
            wet[i] = s * wet[i] + (1 - s) * dry[i]
        }
        currentStrength = s1

        // Mode / enable switch: 10 ms equal-gain crossfade from the old path's output.
        if let old = fadingOut {
            runPath(old, wet: &oldWet, dry: &oldDry)
            let so = fadingOutStrength
            for i in 0..<n {
                let oldOut = so * oldWet[i] + (1 - so) * oldDry[i]
                let t = Float(i + 1) / Float(n)
                wet[i] = t * wet[i] + (1 - t) * oldOut
            }
            fadingOut = nil
        }
    }

    private func runPath(_ path: DenoisePath, wet: inout [Float], dry: inout [Float]) {
        blockIn.withUnsafeBufferPointer { input in
            wet.withUnsafeMutableBufferPointer { w in
                path.engine.process(input.baseAddress!, w.baseAddress!)
            }
            dry.withUnsafeMutableBufferPointer { d in
                path.dry.process(input.baseAddress!, d.baseAddress!, count: Self.blockSize)
            }
        }
    }
}
