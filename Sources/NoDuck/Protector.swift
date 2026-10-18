import CoreAudio
import Foundation

/// Keeps other apps at full volume on one output device for as long as it is running.
///
/// Every process playing to `device`, except the excluded ones (the call and NoDuck itself), is muted by a Core Audio
/// process tap and its sound is played back to the same device by NoDuck. NoDuck also holds a duck request of its own
/// (0.999, i.e. -0.01 dB). The audio server never ducks a process that holds one, so the call app can duck "other
/// audio" as much as it likes: the original apps are muted anyway, and the replay is exempt.
///
/// If NoDuck quits or crashes, the tap and the duck request go away with it and the apps play directly again.
final class Protector {
    let device: AudioObjectID
    let deviceName: String
    let startedAt = Date()
    private(set) var excluded: Set<AudioObjectID>
    /// The audio server's answer to the duck request, once it has been made (shortly after start).
    private(set) var duckStatus: OSStatus?
    /// Whether the tap has delivered any sound yet.
    var hasHeardSound: Bool { io.pointee.heardSound }

    private let tapDescription: CATapDescription
    private let sampleRate: Float64
    private let outputChannels: Int
    private var tap = CA.unknown
    private var tapFormat = AudioStreamBasicDescription()
    private var aggregate = CA.unknown
    private var ioProc: AudioDeviceIOProcID?
    private var stopped = false
    /// Shared with the I/O thread, which only stores plain values into it.
    private let io: UnsafeMutablePointer<IOState>

    /// Written by the I/O thread: whether sound arrived, and what the first callback looked like (for the log).
    struct IOState {
        var heardSound = false
        var sawFirstCallback = false
        var inputBuffers = 0
        /// Bit n set: input buffer n arrived without data (a stream that is turned off).
        var emptyInputBuffers: UInt64 = 0
        var tapChannels = 0
        var outputBuffers = 0
        var outputChannels = 0
    }

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(CA.describe(status)))" }
    }

    init(device: AudioObjectID, excluding: Set<AudioObjectID>) throws {
        guard let uid = CA.deviceUID(device) else {
            throw Failure(step: "reading the device UID", status: kAudioHardwareBadDeviceError)
        }
        self.device = device
        deviceName = CA.name(device)
        excluded = excluding
        sampleRate = CA.nominalSampleRate(device)
        outputChannels = CA.channelCount(device, kAudioObjectPropertyScopeOutput)
        io = .allocate(capacity: 1)
        io.initialize(to: IOState())

        let description = CATapDescription(excludingProcesses: Array(excluding), deviceUID: uid, stream: 0)
        description.name = "NoDuck"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapDescription = description

        do {
            try start(uid: uid)
        } catch {
            teardown()
            throw error
        }
        Log.info("protecting \(deviceName) (\(device)), excluding processes \(excluded.sorted()), "
                 + "ready in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
        // The audio server mutes the tapped apps a few tens of milliseconds after I/O starts. A duck request made
        // before that would hand them the call's full duck at once, and the tap would replay that. So wait for the
        // first sound (at most 0.25 s: with nothing playing there is nothing to replay).
        requestDuckOnceHeard(deadline: Date().addingTimeInterval(0.25))
    }

    deinit {
        teardown()
        io.deallocate()
    }

    private func start(uid: String) throws {
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr else { throw Failure(step: "creating the process tap", status: status) }
        tapFormat = CA.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        if tapFormat.mFormatID != 0 && !Self.isFloat32(tapFormat) {
            throw Failure(step: "tap format check (not 32-bit float)", status: kAudioDeviceUnsupportedFormatError)
        }

        // A private aggregate device of the real device (the clock, and where the replay goes) plus the tap.
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NoDuck",
            kAudioAggregateDeviceUIDKey: "local.noduck.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        guard status == noErr else { throw Failure(step: "creating the aggregate device", status: status) }

        // The aggregate's input streams are the device's own inputs (a headset microphone, say), then the tap.
        let deviceInputs = CA.streams(device, kAudioObjectPropertyScopeInput).count
        let aggregateInputs = CA.streams(aggregate, kAudioObjectPropertyScopeInput)
        guard aggregateInputs.count > deviceInputs else {
            throw Failure(step: "finding the tap's stream", status: kAudioHardwareBadStreamError)
        }
        let deviceFormats = aggregateInputs.prefix(deviceInputs).map(Self.virtualFormat)
        let tapFormats = aggregateInputs.dropFirst(deviceInputs).map(Self.virtualFormat)
        if deviceInputs > 0 {
            // That order decides which streams get turned off and which buffers get played, so check it against the
            // channel counts: getting it wrong would play the headset's microphone into the headset.
            let deviceChannels = deviceFormats.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
            let tapChannels = tapFormats.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
            let expectedDevice = CA.channelCount(device, kAudioObjectPropertyScopeInput)
            if (expectedDevice > 0 && deviceChannels > 0 && deviceChannels != expectedDevice)
                || (tapFormat.mChannelsPerFrame > 0 && tapChannels > 0 && tapChannels != Int(tapFormat.mChannelsPerFrame)) {
                throw Failure(step: "checking the stream layout (device \(deviceChannels)/\(expectedDevice) ch, "
                                    + "tap \(tapChannels)/\(tapFormat.mChannelsPerFrame) ch)",
                              status: kAudioHardwareBadStreamError)
            }
        }
        var tapBuffers = 0
        for format in tapFormats {
            tapBuffers += Self.bufferCount(format.mFormatID != 0 ? format : tapFormat)
        }
        for stream in CA.streams(aggregate, kAudioObjectPropertyScopeOutput) {
            let format = Self.virtualFormat(stream)
            if format.mFormatID != 0 && !Self.isFloat32(format) {
                throw Failure(step: "output format check (not 32-bit float)", status: kAudioDeviceUnsupportedFormatError)
            }
        }

        let state = io
        let tapBufferCount = tapBuffers
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
            Protector.render(from: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                             tapBuffers: tapBufferCount, to: UnsafeMutableAudioBufferListPointer(output), state: state)
        }
        guard status == noErr, let ioProc else { throw Failure(step: "creating the I/O proc", status: status) }

        if deviceInputs > 0 {
            status = useOnlyTapInputs(ioProc, deviceInputs: deviceInputs, totalInputs: aggregateInputs.count)
            // A Bluetooth headset whose microphone gets opened drops to its low-quality headset mode, for every app.
            // A wired one is merely opened, so carry on there.
            if status != noErr && Self.isBluetooth(device) {
                throw Failure(step: "turning off the headset's microphone", status: status)
            }
        }

        status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else { throw Failure(step: "starting the aggregate device", status: status) }
        Log.info("tap \(tap), aggregate \(aggregate), \(tapBuffers) tap buffer(s), \(deviceInputs) device input stream(s), "
                 + "\(Int(sampleRate)) Hz, \(outputChannels) output channel(s)")
    }

    /// Takes more processes out of the running tap (a call app that started later). Changing the process list does
    /// not interrupt the replay, unlike a new tap. Returns false if the tap refused the change.
    func exclude(_ more: Set<AudioObjectID>) -> Bool {
        let alive = Set(CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList))
        let updated = excluded.intersection(alive).union(more)
        tapDescription.processes = Array(updated)
        var address = CA.address(kAudioTapPropertyDescription)
        var value = tapDescription
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else {
            tapDescription.processes = Array(excluded)
            Log.info("the tap refused a new process list (\(CA.describe(status))), rebuilding it")
            return false
        }
        excluded = updated
        Log.info("now excluding processes \(updated.sorted())")
        return true
    }

    func stop() {
        guard !stopped else { return }
        teardown()
        Log.info("stopped protecting \(deviceName)")
    }

    private func teardown() {
        stopped = true
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if duckStatus == noErr {
            Duck.request(device, level: 1.0)
            duckStatus = nil
        }
        if aggregate != CA.unknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = CA.unknown
        }
        if tap != CA.unknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = CA.unknown
        }
    }

    private func requestDuckOnceHeard(deadline: Date) {
        guard !stopped else { return }
        guard io.pointee.heardSound || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.requestDuckOnceHeard(deadline: deadline)
            }
            return
        }
        let status = Duck.request(device, level: 0.999)
        duckStatus = status
        Log.info("duck request 0.999 on \(deviceName): \(CA.describe(status))"
                 + (io.pointee.heardSound ? "" : " (nothing playing yet)"))
        let state = io.pointee
        if state.sawFirstCallback {
            let empty = (0..<min(state.inputBuffers, 64)).filter { state.emptyInputBuffers & (1 << UInt64($0)) != 0 }
            Log.info("first I/O cycle: \(state.inputBuffers) input buffer(s), empty: \(empty), "
                     + "\(state.tapChannels) tap channel(s) -> \(state.outputBuffers) output buffer(s), "
                     + "\(state.outputChannels) channel(s)")
        }
    }

    /// False when the tap needs rebuilding: the device or the aggregate went away, or the sample rate, channel layout
    /// or tap format changed (a Bluetooth headset switching to its headset mode, for example). The controller asks
    /// at least once a second and on every audio event, which is as often as it would rebuild anyway.
    func isStillValid() -> Bool {
        guard !stopped else { return false }
        // A property that can't be read counts as unchanged: rebuilding on a hiccup would interrupt the sound.
        let channels = CA.channelCount(device, kAudioObjectPropertyScopeOutput)
        let format = CA.value(tap, kAudioTapPropertyFormat, tapFormat)
        let reason: String
        if !CA.devices().contains(device) || CA.value(device, kAudioDevicePropertyDeviceIsAlive, UInt32(1)) == 0
            || CA.deviceUID(aggregate) == nil {
            reason = "the device went away"
        } else if CA.value(device, kAudioDevicePropertyNominalSampleRate, sampleRate) != sampleRate {
            reason = "the sample rate changed"
        } else if channels > 0 && channels != outputChannels {
            reason = "the channel layout changed"
        } else if format.mSampleRate != tapFormat.mSampleRate || format.mChannelsPerFrame != tapFormat.mChannelsPerFrame
                    || format.mFormatFlags != tapFormat.mFormatFlags {
            reason = "the tap format changed"
        } else {
            return true
        }
        Log.info("\(deviceName): \(reason), rebuilding")
        return false
    }

    /// Only the tap's input streams are wanted, so the device's own inputs are turned off for this I/O proc. Their
    /// buffers then arrive empty, ahead of the tap's. Returns noErr once the audio server confirms the setting.
    private func useOnlyTapInputs(_ ioProc: AudioDeviceIOProcID, deviceInputs: Int, totalInputs: Int) -> OSStatus {
        typealias Usage = AudioHardwareIOProcStreamUsage
        let procOffset = MemoryLayout<Usage>.offset(of: \Usage.mIOProc) ?? 0
        let countOffset = MemoryLayout<Usage>.offset(of: \Usage.mNumberStreams) ?? 8
        let flagsOffset = MemoryLayout<Usage>.offset(of: \Usage.mStreamIsOn) ?? 12
        let size = flagsOffset + MemoryLayout<UInt32>.size * totalInputs
        let capacity = max(size, MemoryLayout<Usage>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<Usage>.alignment)
        defer { raw.deallocate() }
        func prepare(on: (Int) -> Bool) {
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
            raw.storeBytes(of: unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self), toByteOffset: procOffset,
                           as: UnsafeMutableRawPointer.self)
            raw.storeBytes(of: UInt32(totalInputs), toByteOffset: countOffset, as: UInt32.self)
            for index in 0..<totalInputs {
                raw.storeBytes(of: on(index) ? 1 : 0, toByteOffset: flagsOffset + 4 * index, as: UInt32.self)
            }
        }

        var address = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        prepare { $0 >= deviceInputs }
        var status = AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), raw)
        // Read it back where possible: the audio server takes the I/O proc from the buffer and fills in the flags.
        var readSize = UInt32(size)
        prepare { _ in false }
        if status == noErr, AudioObjectGetPropertyData(aggregate, &address, 0, nil, &readSize, raw) == noErr {
            let confirmed = (0..<totalInputs).allSatisfy {
                raw.load(fromByteOffset: flagsOffset + 4 * $0, as: UInt32.self) == ($0 >= deviceInputs ? 1 : 0)
            }
            if !confirmed { status = kAudioHardwareUnspecifiedError }
        }
        Log.info("turning off \(deviceInputs) device input stream(s): \(CA.describe(status))")
        return status
    }

    private static func virtualFormat(_ stream: AudioObjectID) -> AudioStreamBasicDescription {
        CA.value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
    }

    private static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let transport = CA.transportType(device)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// How many AudioBuffers a stream of this format contributes to an I/O proc's buffer list.
    private static func bufferCount(_ format: AudioStreamBasicDescription) -> Int {
        format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(max(format.mChannelsPerFrame, 1)) : 1
    }

    // MARK: - Real-time I/O thread: no allocation, no locks, no Objective-C.

    /// The tap is the last `tapBuffers` buffers of the input list, Float32. Output channel n plays tap channel n; a
    /// mono tap feeds every output channel and a mono device gets a downmix.
    private static func render(from input: UnsafeMutableAudioBufferListPointer, tapBuffers: Int,
                               to output: UnsafeMutableAudioBufferListPointer, state: UnsafeMutablePointer<IOState>) {
        var outputChannels = 0
        for buffer in output {
            outputChannels += Int(buffer.mNumberChannels)
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let firstTap = input.count - tapBuffers
        var tapChannels = 0
        if tapBuffers > 0 && firstTap >= 0 {
            for index in firstTap..<input.count where input[index].mData != nil {
                tapChannels += Int(input[index].mNumberChannels)
            }
        }
        if !state.pointee.sawFirstCallback {
            var empty: UInt64 = 0
            for index in 0..<min(input.count, 64) where input[index].mData == nil { empty |= 1 << UInt64(index) }
            state.pointee.inputBuffers = input.count
            state.pointee.emptyInputBuffers = empty
            state.pointee.tapChannels = tapChannels
            state.pointee.outputBuffers = output.count
            state.pointee.outputChannels = outputChannels
            state.pointee.sawFirstCallback = true
        }
        guard tapChannels > 0, outputChannels > 0 else { return }
        if !state.pointee.heardSound && containsSound(input, from: firstTap) { state.pointee.heardSound = true }

        let downmix = outputChannels == 1 && tapChannels > 1
        var base = 0
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            defer { base += channels }
            guard channels > 0, let out = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            for channel in 0..<channels {
                if downmix {
                    let scale = 1 / Float32(tapChannels)
                    for source in 0..<tapChannels {
                        mix(input, firstTap: firstTap, channel: source, into: out + channel, stride: channels,
                            frames: frames, scale: scale)
                    }
                } else {
                    let source = tapChannels == 1 ? 0 : base + channel
                    guard source < tapChannels else { continue }
                    mix(input, firstTap: firstTap, channel: source, into: out + channel, stride: channels,
                        frames: frames, scale: 1)
                }
            }
        }
    }

    /// Adds tap channel `channel` (counted across the tap's buffers) times `scale` to every `stride`-th sample of `out`.
    @inline(__always)
    private static func mix(_ input: UnsafeMutableAudioBufferListPointer, firstTap: Int, channel: Int,
                            into out: UnsafeMutablePointer<Float32>, stride: Int, frames: Int, scale: Float32) {
        var remaining = channel
        for index in firstTap..<input.count {
            let buffer = input[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            guard remaining < channels else {
                remaining -= channels
                continue
            }
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels))
            for frame in 0..<count {
                out[frame * stride] += data[frame * channels + remaining] * scale
            }
            return
        }
    }

    private static func containsSound(_ input: UnsafeMutableAudioBufferListPointer, from firstTap: Int) -> Bool {
        for index in firstTap..<input.count {
            guard let data = input[index].mData?.assumingMemoryBound(to: Float32.self) else { continue }
            for sample in 0..<Int(input[index].mDataByteSize) / MemoryLayout<Float32>.size where abs(data[sample]) > 1e-5 {
                return true
            }
        }
        return false
    }
}
