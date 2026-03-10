import CoreAudio
import AudioToolbox
import Foundation
import Darwin

// MARK: - Globals
var verboseMode = false

// MARK: - Helpers

func debugLog(_ msg: String) {
    if verboseMode {
        fputs("[DEBUG] \(msg)\n", stderr)
    }
}

func checkErr(_ status: OSStatus, _ op: String) {
    guard status != noErr else { return }
    fputs("Error: \(op) failed (\(status))\n", stderr); exit(1)
}

// MARK: - Lock-Free Ring Buffer (SPSC, power-of-2)

final class RingBuffer {
    private let cap: Int, mask: Int
    private let buf: UnsafeMutablePointer<Float>
    private var wi = 0, ri = 0
    private var lock = os_unfair_lock_s()

    init(capacity: Int) {
        var c = 1; while c < capacity { c <<= 1 }
        cap = c; mask = c - 1
        buf = .allocate(capacity: c)
        buf.initialize(repeating: 0, count: c)
    }
    deinit { buf.deallocate() }

    var readable: Int {
        os_unfair_lock_lock(&lock)
        let r = (wi &- ri) & mask
        os_unfair_lock_unlock(&lock)
        return r
    }

    func write(_ src: UnsafePointer<Float>, count n: Int) {
        os_unfair_lock_lock(&lock)
        let avail = cap - ((wi &- ri) & mask) - 1
        let w = min(n, avail)
        for i in 0..<w { buf[(wi &+ i) & mask] = src[i] }
        wi = (wi &+ w) & mask
        os_unfair_lock_unlock(&lock)
    }

    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let avail = (wi &- ri) & mask
        let take = min(n, avail)
        for i in 0..<take { dst[i] = buf[(ri &+ i) & mask] }
        ri = (ri &+ take) & mask
        os_unfair_lock_unlock(&lock)
        
        if take < n { memset(dst + take, 0, (n - take) * 4) }
        return take
    }

    /// Skip ahead by n samples (advance read index without copying)
    func skip(_ n: Int) {
        os_unfair_lock_lock(&lock)
        let avail = (wi &- ri) & mask
        let take = min(n, avail)
        ri = (ri &+ take) & mask
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - Level Meter

final class LevelMeter {
    var inPeak: Float = 0, outPeak: Float = 0
    var inCb = 0, outCb = 0

    func recIn(_ d: UnsafePointer<Float>, _ n: Int) {
        var p: Float = 0
        for i in 0..<n { let v = abs(d[i]); if v > p { p = v } }
        inPeak = p; inCb += 1
    }
    func recOut(_ d: UnsafePointer<Float>, _ n: Int) {
        var p: Float = 0
        for i in 0..<n { let v = abs(d[i]); if v > p { p = v } }
        outPeak = p; outCb += 1
    }
}

// MARK: - Device Enumeration

struct AudioDev {
    let id: AudioDeviceID
    let name: String
    let channels: Int
}

struct DataSource {
    let id: UInt32
    let name: String
}

func getInputDevices() -> [AudioDev] {
    debugLog("Fetching hardware devices...")
    var sz: UInt32 = 0
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz)
    let cnt = Int(sz) / MemoryLayout<AudioDeviceID>.size
    debugLog("Found \(cnt) total hardware devices. Filtering for inputs...")
    var ids = [AudioDeviceID](repeating: 0, count: cnt)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &ids)

    var result: [AudioDev] = []
    for id in ids {
        let ch = getDeviceInputChannels(id)
        guard ch > 0 else { continue }
        result.append(AudioDev(id: id, name: getDeviceName(id), channels: ch))
    }
    return result
}

func getDeviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
    var uName: Unmanaged<CFString>?
    if AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &uName) == noErr,
       let cf = uName?.takeUnretainedValue() { return cf as String }
    return "Unknown"
}

func getDeviceInputChannels(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr else { return 0 }
    let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(sz)); defer { mem.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, mem) == noErr else { return 0 }
    let abl = UnsafeMutableRawPointer(mem).bindMemory(to: AudioBufferList.self, capacity: 1)
    var ch = 0
    for b in UnsafeMutableAudioBufferListPointer(abl) { ch += Int(b.mNumberChannels) }
    return ch
}

func getDeviceOutputChannels(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr else { return 2 }
    let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(sz)); defer { mem.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, mem) == noErr else { return 2 }
    let abl = UnsafeMutableRawPointer(mem).bindMemory(to: AudioBufferList.self, capacity: 1)
    var ch: UInt32 = 0
    for b in UnsafeMutableAudioBufferListPointer(abl) { ch += b.mNumberChannels }
    return max(ch, 1)
}

func getDefaultOutputDeviceID() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0; var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    checkErr(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id), "GetDefaultOutput")
    return id
}

func getDeviceSampleRate(_ id: AudioDeviceID) -> Float64 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sr: Float64 = 0; var sz = UInt32(MemoryLayout<Float64>.size)
    checkErr(AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &sr), "GetSR"); return sr
}

func setDeviceBufferSize(_ id: AudioDeviceID, _ frames: UInt32) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var f = frames
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &f)
}

func getDeviceBufferSize(_ id: AudioDeviceID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var f: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &f); return f
}

// MARK: - Data Sources

func getDataSources(_ deviceID: AudioDeviceID) -> [DataSource] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSources, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sz) == noErr, sz > 0 else { return [] }

    let count = Int(sz) / MemoryLayout<UInt32>.size
    var sourceIDs = [UInt32](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &sourceIDs) == noErr else { return [] }

    debugLog("Found \(count) data sources for device \(deviceID).")
    var sources: [DataSource] = []
    for srcID in sourceIDs {
        // Get source name
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSourceNameForIDCFString, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var translation = AudioValueTranslation(
            mInputData: UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<UInt32>.size, alignment: 4),
            mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
            mOutputData: UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Unmanaged<CFString>>.size, alignment: 8),
            mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        )
        translation.mInputData.storeBytes(of: srcID, as: UInt32.self)

        var transSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let name: String
        if AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &transSize, &translation) == noErr {
            let uName = translation.mOutputData.load(as: Unmanaged<CFString>.self)
            name = uName.takeUnretainedValue() as String
        } else {
            name = "Source \(srcID)"
        }

        translation.mInputData.deallocate()
        translation.mOutputData.deallocate()

        sources.append(DataSource(id: srcID, name: name))
    }
    return sources
}

func getCurrentDataSource(_ deviceID: AudioDeviceID) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var srcID: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &srcID) == noErr { return srcID }
    return nil
}

func setDataSource(_ deviceID: AudioDeviceID, sourceID: UInt32) -> Bool {
    if getCurrentDataSource(deviceID) == sourceID {
        debugLog("Data source is already set to ID \(sourceID) for device \(deviceID).")
        return true
    }

    debugLog("Attempting to set data source to ID \(sourceID) for device \(deviceID)...")
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var sid = sourceID
    let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &sid)
    if status != noErr {
        if getCurrentDataSource(deviceID) == sourceID {
            debugLog("AudioObjectSetPropertyData returned OSStatus \(status), but source successfully changed to ID \(sourceID).")
            return true
        } else {
            debugLog("AudioObjectSetPropertyData kAudioDevicePropertyDataSource failed with OSStatus \(status).")
            return false
        }
    } else {
        debugLog("Successfully set data source to ID \(sourceID).")
        return true
    }
}

// MARK: - Stream Format Query

func getInputStreamFormat(_ deviceID: AudioDeviceID) -> AudioStreamBasicDescription {
    // Get the physical (native) format of the input stream
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var fmt = AudioStreamBasicDescription()
    var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, &fmt) == noErr {
        return fmt
    }
    // fallback
    fmt.mSampleRate = 44100
    fmt.mFormatID = kAudioFormatLinearPCM
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    fmt.mBitsPerChannel = 32
    fmt.mChannelsPerFrame = 1
    fmt.mBytesPerFrame = 4
    fmt.mFramesPerPacket = 1
    fmt.mBytesPerPacket = 4
    return fmt
}

func describeFormat(_ fmt: AudioStreamBasicDescription) -> String {
    let isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isInt = (fmt.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    let isPacked = (fmt.mFormatFlags & kAudioFormatFlagIsPacked) != 0
    let isNonInterleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let isBE = (fmt.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0

    var parts: [String] = []
    if isFloat { parts.append("Float\(fmt.mBitsPerChannel)") }
    else if isInt { parts.append("Int\(fmt.mBitsPerChannel)") }
    else { parts.append("\(fmt.mBitsPerChannel)bit") }
    if isPacked { parts.append("packed") }
    if isNonInterleaved { parts.append("non-interleaved") } else { parts.append("interleaved") }
    if isBE { parts.append("BE") } else { parts.append("LE") }
    parts.append("\(fmt.mChannelsPerFrame)ch")
    parts.append("\(fmt.mSampleRate)Hz")
    return parts.joined(separator: " ")
}

// MARK: - Passthrough Context

final class PassthroughCtx {
    let ringL: RingBuffer, ringR: RingBuffer
    let meter: LevelMeter
    let inputChannels: Int
    let isFloat: Bool
    let isNonInterleaved: Bool
    let bitsPerChannel: UInt32
    let bytesPerFrame: UInt32
    let outputSampleRate: Float64
    let targetLatencySamples: Int  // max samples in ring before we skip
    var convBuf: UnsafeMutablePointer<Float>
    var currentLatencySamples: Int = 0  // updated by output callback
    var underruns: Int = 0

    init(inputChannels: Int, fmt: AudioStreamBasicDescription, ringCapacity: Int,
         outputSR: Float64, targetLatencyMs: Double) {
        self.inputChannels = inputChannels
        self.isFloat = (fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        self.isNonInterleaved = (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        self.bitsPerChannel = fmt.mBitsPerChannel
        self.bytesPerFrame = fmt.mBytesPerFrame
        self.outputSampleRate = outputSR
        self.targetLatencySamples = Int(outputSR * targetLatencyMs / 1000.0)
        self.meter = LevelMeter()
        ringL = RingBuffer(capacity: ringCapacity)
        ringR = RingBuffer(capacity: ringCapacity)
        convBuf = .allocate(capacity: 65536)
    }
    deinit { convBuf.deallocate() }
}

// MARK: - Format Conversion Helpers

/// Convert a buffer of samples in the device's native format to Float32
func convertToFloat(_ src: UnsafeRawPointer, dst: UnsafeMutablePointer<Float>, frames: Int,
                    isFloat: Bool, bits: UInt32, channelsInBuf: Int, channelToExtract: Int) {
    if isFloat && bits == 32 {
        if channelsInBuf == 1 {
            memcpy(dst, src, frames * 4)
        } else {
            let p = src.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { dst[i] = p[i * channelsInBuf + channelToExtract] }
        }
    } else if !isFloat && bits == 16 {
        let p = src.assumingMemoryBound(to: Int16.self)
        let scale: Float = 1.0 / 32768.0
        if channelsInBuf == 1 {
            for i in 0..<frames { dst[i] = Float(p[i]) * scale }
        } else {
            for i in 0..<frames { dst[i] = Float(p[i * channelsInBuf + channelToExtract]) * scale }
        }
    } else if !isFloat && bits == 24 {
        // 24-bit packed: 3 bytes per sample per channel
        let p = src.assumingMemoryBound(to: UInt8.self)
        let bytesPerSample = 3
        let stride = bytesPerSample * channelsInBuf
        let scale: Float = 1.0 / 8388608.0  // 2^23
        for i in 0..<frames {
            let offset = i * stride + channelToExtract * bytesPerSample
            // Little-endian 24-bit signed
            let b0 = Int32(p[offset])
            let b1 = Int32(p[offset + 1])
            let b2 = Int32(p[offset + 2])
            var val = b0 | (b1 << 8) | (b2 << 16)
            if val & 0x800000 != 0 { val |= -16777216 }  // sign extend
            dst[i] = Float(val) * scale
        }
    } else if !isFloat && bits == 32 {
        let p = src.assumingMemoryBound(to: Int32.self)
        let scale: Float = 1.0 / 2147483648.0  // 2^31
        if channelsInBuf == 1 {
            for i in 0..<frames { dst[i] = Float(p[i]) * scale }
        } else {
            for i in 0..<frames { dst[i] = Float(p[i * channelsInBuf + channelToExtract]) * scale }
        }
    } else {
        // Unknown format: silence
        memset(dst, 0, frames * 4)
    }
}

// MARK: - Input IOProc

func inputIOProc(
    _ deviceID: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = clientData else { return noErr }
    let ctx = Unmanaged<PassthroughCtx>.fromOpaque(clientData).takeUnretainedValue()
    let bufs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard bufs.count > 0, let data0 = bufs[0].mData else { return noErr }

    let buf0 = bufs[0]
    let channelsInBuf = Int(buf0.mNumberChannels)

    // Calculate frame count
    let bytesPerSampleChannel: Int
    if ctx.isFloat { bytesPerSampleChannel = Int(ctx.bitsPerChannel) / 8 }
    else { bytesPerSampleChannel = Int(ctx.bitsPerChannel) / 8 }

    let frameCount: Int
    if ctx.isNonInterleaved {
        frameCount = Int(buf0.mDataByteSize) / bytesPerSampleChannel
    } else {
        frameCount = Int(buf0.mDataByteSize) / (bytesPerSampleChannel * channelsInBuf)
    }

    guard frameCount > 0 else { return noErr }

    let conv = ctx.convBuf

    if ctx.isNonInterleaved {
        // Each buffer in the list is a separate channel
        // Left = buffer 0
        convertToFloat(data0, dst: conv, frames: frameCount,
                       isFloat: ctx.isFloat, bits: ctx.bitsPerChannel,
                       channelsInBuf: 1, channelToExtract: 0)
        ctx.meter.recIn(conv, frameCount)
        ctx.ringL.write(conv, count: frameCount)

        // Right = buffer 1 or duplicate
        if bufs.count >= 2, let data1 = bufs[1].mData {
            convertToFloat(data1, dst: conv, frames: frameCount,
                           isFloat: ctx.isFloat, bits: ctx.bitsPerChannel,
                           channelsInBuf: 1, channelToExtract: 0)
        }
        ctx.ringR.write(conv, count: frameCount)
    } else {
        // Interleaved: extract channels
        convertToFloat(data0, dst: conv, frames: frameCount,
                       isFloat: ctx.isFloat, bits: ctx.bitsPerChannel,
                       channelsInBuf: channelsInBuf, channelToExtract: 0)
        ctx.meter.recIn(conv, frameCount)
        ctx.ringL.write(conv, count: frameCount)

        let rCh = min(1, channelsInBuf - 1)
        convertToFloat(data0, dst: conv, frames: frameCount,
                       isFloat: ctx.isFloat, bits: ctx.bitsPerChannel,
                       channelsInBuf: channelsInBuf, channelToExtract: rCh)
        ctx.ringR.write(conv, count: frameCount)
    }

    return noErr
}

// MARK: - Output Render Callback

func outputRenderCB(
    _ ref: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let ctx = Unmanaged<PassthroughCtx>.fromOpaque(ref).takeUnretainedValue()
    guard let ioData = ioData else { return noErr }

    // Latency management: if ring buffer has too much data, skip ahead
    let fillL = ctx.ringL.readable
    let target = ctx.targetLatencySamples
    // Use a hard limit to avoid constant skipping due to jitter.
    // E.g., double the target latency, but at least +2048 samples.
    let hardLimit = max(target * 2, target + 2048)
    
    if fillL > hardLimit {
        let skip = fillL - target
        ctx.ringL.skip(skip)
        ctx.ringR.skip(skip)
    }

    // Track current latency for display
    ctx.currentLatencySamples = ctx.ringL.readable

    let out = UnsafeMutableAudioBufferListPointer(ioData)
    var underrun = false
    
    if out.count >= 1, let d = out[0].mData?.assumingMemoryBound(to: Float.self) {
        let taken = ctx.ringL.read(d, count: Int(frames))
        if taken < Int(frames) { underrun = true }
        ctx.meter.recOut(d, Int(frames))
    }
    if out.count >= 2, let d = out[1].mData?.assumingMemoryBound(to: Float.self) {
        let taken = ctx.ringR.read(d, count: Int(frames))
        if taken < Int(frames) { underrun = true }
    }
    
    if underrun {
        ctx.underruns &+= 1
    }
    
    return noErr
}

// MARK: - Passthrough Engine

class AudioPassthrough {
    let inDevID: AudioDeviceID, outDevID: AudioDeviceID, bufFrames: UInt32
    let targetLatencyMs: Double
    let showMeter: Bool
    var ctx: PassthroughCtx?
    var inProcID: AudioDeviceIOProcID?
    var outUnit: AudioComponentInstance?

    init(inDev: AudioDeviceID, buf: UInt32, targetLatencyMs: Double, showMeter: Bool) {
        inDevID = inDev; outDevID = getDefaultOutputDeviceID(); bufFrames = buf
        self.targetLatencyMs = targetLatencyMs; self.showMeter = showMeter
    }

    func start() {
        debugLog("Starting passthrough engine...")
        debugLog("Setting input device (\(inDevID)) buffer size to \(bufFrames)...")
        setDeviceBufferSize(inDevID, bufFrames)
        debugLog("Setting output device (\(outDevID)) buffer size to \(bufFrames)...")
        setDeviceBufferSize(outDevID, bufFrames)

        let inSR = getDeviceSampleRate(inDevID)
        let outSR = getDeviceSampleRate(outDevID)
        let outCh = getDeviceOutputChannels(outDevID)
        let inFmt = getInputStreamFormat(inDevID)

        fputs("Input format:  \(describeFormat(inFmt))\n", stderr)
        fputs("Input buffer:  \(getDeviceBufferSize(inDevID)) frames\n", stderr)
        fputs("Output:        \(outSR)Hz, \(outCh)ch, buffer \(getDeviceBufferSize(outDevID)) frames\n", stderr)
        fputs("Target latency: \(String(format:"%.0f", targetLatencyMs)) ms\n", stderr)

        // Try to match sample rates
        if inSR != outSR {
            fputs("⚠ Sample rate mismatch (\(inSR) vs \(outSR)). Trying to set input to \(outSR)...\n", stderr)
            var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var newSR = outSR
            if AudioObjectSetPropertyData(inDevID, &srAddr, 0, nil, UInt32(MemoryLayout<Float64>.size), &newSR) == noErr {
                let actual = getDeviceSampleRate(inDevID)
                fputs("  → Input now at \(actual) Hz\n", stderr)
            } else {
                fputs("  → Failed. Audio may have pitch issues.\n", stderr)
            }
        }

        let finalFmt = getInputStreamFormat(inDevID)
        let inCh = getDeviceInputChannels(inDevID)

        // Ring buffer: just enough for target latency + headroom (min 0.5s capacity)
        let ringCap = max(Int(outSR * 0.5), Int(outSR * targetLatencyMs / 1000.0) * 4)
        ctx = PassthroughCtx(inputChannels: inCh, fmt: finalFmt, ringCapacity: ringCap,
                             outputSR: outSR, targetLatencyMs: targetLatencyMs)
        let ctxPtr = Unmanaged.passUnretained(ctx!).toOpaque()

        // --- Input: HAL IOProc ---
        checkErr(AudioDeviceCreateIOProcID(inDevID, inputIOProc, ctxPtr, &inProcID), "CreateIOProc")
        checkErr(AudioDeviceStart(inDevID, inProcID), "StartInput")

        // --- Output: AUHAL ---
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { fputs("No HAL Output\n", stderr); exit(1) }
        checkErr(AudioComponentInstanceNew(comp, &outUnit), "OutUnit:New")

        var oid = outDevID
        checkErr(AudioUnitSetProperty(outUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &oid, UInt32(MemoryLayout<AudioDeviceID>.size)), "OutUnit:Dev")

        var fmt = AudioStreamBasicDescription(
            mSampleRate: outSR, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: outCh, mBitsPerChannel: 32, mReserved: 0)
        checkErr(AudioUnitSetProperty(outUnit!, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &fmt,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "OutUnit:Fmt")

        var mf: UInt32 = 4096
        checkErr(AudioUnitSetProperty(outUnit!, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &mf, UInt32(MemoryLayout<UInt32>.size)), "OutUnit:MaxF")

        var cb = AURenderCallbackStruct(inputProc: outputRenderCB, inputProcRefCon: ctxPtr)
        checkErr(AudioUnitSetProperty(outUnit!, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &cb,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "OutUnit:CB")

        checkErr(AudioUnitInitialize(outUnit!), "OutUnit:Init")
        checkErr(AudioOutputUnitStart(outUnit!), "OutUnit:Start")

        fputs("Passthrough ACTIVE. Ctrl+C to stop.\n\n", stderr)
    }

    func runLoop() {
        guard let ctx = ctx else { return }
        if showMeter {
            var lastUnderruns = 0
            while true {
                usleep(80_000)
                let m = ctx.meter
                let inDb  = m.inPeak > 0 ? 20 * log10(Double(m.inPeak)) : -96
                let outDb = m.outPeak > 0 ? 20 * log10(Double(m.outPeak)) : -96
                let latMs = Double(ctx.currentLatencySamples) / ctx.outputSampleRate * 1000.0
                let und = ctx.underruns
                let undStr = und > 0 ? "  \u{1B}[31mUNDERRUNS: \(und)\u{1B}[0m" : ""
                
                fputs("\r  IN  \(bar(m.inPeak, 30)) \(String(format:"%+6.1f",inDb))dB  \u{1B}[K\n", stderr)
                fputs("\r  OUT \(bar(m.outPeak, 30)) \(String(format:"%+6.1f",outDb))dB  lat:\(String(format:"%.1f",latMs))ms\(undStr)  \u{1B}[K", stderr)
                
                if verboseMode && und > lastUnderruns {
                    fputs("\n[DEBUG] Buffer underrun occurred! Total: \(und)\u{1B}[K\n", stderr)
                    lastUnderruns = und
                } else {
                    fputs("\u{1B}[1A", stderr)
                }
            }
        } else {
            // Quiet mode: check periodically for underruns
            var lastUnderruns = 0
            while true {
                usleep(500_000)
                let und = ctx.underruns
                if und > lastUnderruns {
                    fputs("Warning: Buffer underrun occurred (total: \(und))\n", stderr)
                    lastUnderruns = und
                }
            }
        }
    }
}

func bar(_ peak: Float, _ w: Int) -> String {
    let n = Int(min(max(peak, 0), 1) * Float(w))
    return "[\(String(repeating: "█", count: n))\(String(repeating: "░", count: w - n))]"
}

// MARK: - Interactive Source Selection

func selectSource(deviceID: AudioDeviceID) {
    let sources = getDataSources(deviceID)
    guard sources.count > 1 else { return } // no choice needed

    let current = getCurrentDataSource(deviceID)

    print("\n  Available sources:")
    for (i, src) in sources.enumerated() {
        let marker = (src.id == current) ? " ←" : ""
        print("    [\(i)] \(src.name)\(marker)")
    }
    print("\n  Select source (Enter = keep current): ", terminator: "")

    if let line = readLine(), !line.isEmpty, let idx = Int(line), idx >= 0, idx < sources.count {
        if setDataSource(deviceID, sourceID: sources[idx].id) {
            fputs("  Source set to: \(sources[idx].name)\n", stderr)
        } else {
            fputs("  Failed to set source!\n", stderr)
        }
    } else {
        if let cur = current, let curSrc = sources.first(where: { $0.id == cur }) {
            fputs("  Keeping: \(curSrc.name)\n", stderr)
        }
    }
}

// MARK: - CLI

func printUsage() {
    print("""
    LLPTP - Low Latency PassThrough Player

    Usage:
      llptp --list                         List input devices
      llptp --device <N>                   Start passthrough
      llptp --device <N> --source <S>      Select source on device
      llptp --device <N> -b <frames>       Custom buffer (default: 128)
      llptp                                Interactive mode

    Options:
      --list              List available audio input devices
      --device <N>        Select input device by index
      --source <S>        Select data source by index (mic, line, spdif, etc.)
      --sources <N>       List available sources for device N
      --buffer, -b <frames> Buffer size in frames (default: 128)
      --latency <ms>      Target max latency in ms (default: 10)
      --quiet, -q         No level meters (less CPU)
      --verbose, -v       Verbose output (debug logs)
      --help, -h          Show this message
    """)
}

func runPassthrough(idx: Int, srcIdx: Int?, buf: UInt32, latencyMs: Double, quiet: Bool) {
    debugLog("Initializing passthrough for device index \(idx), source index \(srcIdx ?? -1)")
    let devs = getInputDevices()
    guard idx >= 0, idx < devs.count else {
        fputs("Error: index \(idx) out of range (0-\(devs.count - 1))\n", stderr); exit(1)
    }
    let dev = devs[idx]
    fputs("Device: \(dev.name) (\(dev.channels) ch)\n", stderr)

    // Handle source selection
    let sources = getDataSources(dev.id)
    if let si = srcIdx {
        guard si >= 0, si < sources.count else {
            fputs("Error: source index \(si) out of range (0-\(sources.count - 1))\n", stderr); exit(1)
        }
        if setDataSource(dev.id, sourceID: sources[si].id) {
            fputs("Source: \(sources[si].name)\n", stderr)
        } else {
            fputs("Warning: could not set source to \(sources[si].name)\n", stderr)
        }
    } else if sources.count > 1 {
        // Interactive source selection
        selectSource(deviceID: dev.id)
    }

    if let cur = getCurrentDataSource(dev.id), let s = sources.first(where: { $0.id == cur }) {
        fputs("Active source: \(s.name)\n", stderr)
    }

    let pt = AudioPassthrough(inDev: dev.id, buf: buf, targetLatencyMs: latencyMs, showMeter: !quiet)
    signal(SIGINT) { _ in fputs("\n", stderr); exit(0) }
    pt.start()
    pt.runLoop()
}

// MARK: - Main

var selIdx: Int? = nil
var srcIdx: Int? = nil
var bufFrames: UInt32 = 128
var targetLatencyMs: Double = 10.0
var quietMode = false
var doList = false
var listSourcesDev: Int? = nil

var args = CommandLine.arguments.dropFirst()
while let a = args.first {
    args = args.dropFirst()
    switch a {
    case "--list": doList = true
    case "--device":
        guard let v = args.first, let i = Int(v) else { fputs("--device needs number\n", stderr); exit(1) }
        args = args.dropFirst(); selIdx = i
    case "--source":
        guard let v = args.first, let i = Int(v) else { fputs("--source needs number\n", stderr); exit(1) }
        args = args.dropFirst(); srcIdx = i
    case "--sources":
        guard let v = args.first, let i = Int(v) else { fputs("--sources needs device number\n", stderr); exit(1) }
        args = args.dropFirst(); listSourcesDev = i
    case "--buffer", "-b":
        guard let v = args.first, let f = UInt32(v) else { fputs("-b/--buffer needs number\n", stderr); exit(1) }
        args = args.dropFirst(); bufFrames = f
    case "--latency":
        guard let v = args.first, let ms = Double(v) else { fputs("--latency needs number (ms)\n", stderr); exit(1) }
        args = args.dropFirst(); targetLatencyMs = ms
    case "--quiet", "-q": quietMode = true
    case "--verbose", "-v": verboseMode = true
    case "--help", "-h": printUsage(); exit(0)
    default: fputs("Unknown: \(a)\n", stderr); printUsage(); exit(1)
    }
}

if doList {
    let devs = getInputDevices()
    if devs.isEmpty { print("No input devices."); exit(0) }
    print("Audio input devices:\n")
    for (i, d) in devs.enumerated() {
        let sources = getDataSources(d.id)
        let srcStr = sources.isEmpty ? "" : " [sources: \(sources.map(\.name).joined(separator: ", "))]"
        print("  [\(i)] \(d.name) (\(d.channels) ch)\(srcStr)")
    }
    print()
    exit(0)
}

if let lsd = listSourcesDev {
    let devs = getInputDevices()
    guard lsd >= 0, lsd < devs.count else { fputs("Invalid device index\n", stderr); exit(1) }
    let sources = getDataSources(devs[lsd].id)
    let current = getCurrentDataSource(devs[lsd].id)
    print("Sources for \(devs[lsd].name):\n")
    if sources.isEmpty { print("  No selectable sources.") }
    for (i, s) in sources.enumerated() {
        let marker = s.id == current ? " ← active" : ""
        print("  [\(i)] \(s.name)\(marker)")
    }
    print()
    exit(0)
}

if let i = selIdx {
    runPassthrough(idx: i, srcIdx: srcIdx, buf: bufFrames, latencyMs: targetLatencyMs, quiet: quietMode)
} else {
    let devs = getInputDevices()
    if devs.isEmpty { fputs("No input devices.\n", stderr); exit(1) }
    print("Audio input devices:\n")
    for (i, d) in devs.enumerated() {
        let sources = getDataSources(d.id)
        let srcStr = sources.isEmpty ? "" : " [sources: \(sources.map(\.name).joined(separator: ", "))]"
        print("  [\(i)] \(d.name) (\(d.channels) ch)\(srcStr)")
    }
    print("\nSelect device: ", terminator: "")
    guard let line = readLine(), let i = Int(line), i >= 0, i < devs.count else {
        fputs("Invalid.\n", stderr); exit(1)
    }

    // Interactive source selection if device has multiple sources
    let sources = getDataSources(devs[i].id)
    var selectedSrc: Int? = nil
    if sources.count > 1 {
        let current = getCurrentDataSource(devs[i].id)
        print("\n  Available sources:")
        for (si, s) in sources.enumerated() {
            let marker = s.id == current ? " ←" : ""
            print("    [\(si)] \(s.name)\(marker)")
        }
        print("\n  Select source (Enter = keep current): ", terminator: "")
        if let sline = readLine(), !sline.isEmpty, let si = Int(sline) {
            selectedSrc = si
        }
    }

    print("\n  Enter buffer size in frames (Enter = keep \(bufFrames)): ", terminator: "")
    if let bline = readLine(), !bline.isEmpty, let bf = UInt32(bline) {
        bufFrames = bf
    }

    runPassthrough(idx: i, srcIdx: selectedSrc, buf: bufFrames, latencyMs: targetLatencyMs, quiet: quietMode)
}
