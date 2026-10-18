import CoreAudio
import Darwin
import Foundation
import os

/// Small helpers around the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// A fixed-size property value, or `fallback` if it can't be read.
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var address = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The raw bytes of a property, for looking at undocumented ones in `--diagnose`.
    static func bytes(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt8]? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: Int(size))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &data) == noErr else { return nil }
        return Array(data.prefix(Int(size)))
    }

    static func devices() -> [AudioObjectID] { objects(system, kAudioHardwarePropertyDevices) }

    static func defaultOutputDevice() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, unknown)
    }

    static func device(withUID uid: String) -> AudioObjectID? { devices().first { deviceUID($0) == uid } }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    static func name(_ object: AudioObjectID) -> String { string(object, kAudioObjectPropertyName) ?? "#\(object)" }

    static func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        objects(device, kAudioDevicePropertyStreams, scope: scope)
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Float64 {
        value(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
    }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        value(device, kAudioDevicePropertyTransportType, UInt32(0))
    }

    /// Total channels of the device in one direction.
    static func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr ? object : unknown
    }

    static func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// 'abcd' when the value is four printable characters (most Core Audio codes are), the number otherwise.
    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(value) }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }

    /// "0", or "560226676 '!dat'" for the many statuses that are four-character codes.
    static func describe(_ status: OSStatus) -> String {
        let code = fourCC(UInt32(bitPattern: status))
        return code.hasPrefix("'") ? "\(status) \(code)" : "\(status)"
    }
}

/// `AudioDeviceDuck` is exported by CoreAudio but missing from the public headers (WebKit and Chromium declare it
/// themselves to undo the ducking of their own voice processing). Duck requests are kept per process, and the audio
/// server does not duck a process that holds a duck request of its own: that is what NoDuck relies on.
///
/// The function is looked up at run time, so a macOS without it makes NoDuck do nothing instead of not launching.
enum Duck {
    private typealias Function = @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

    private static let function: Function? = {
        // RTLD_DEFAULT: search every loaded image (CoreAudio is linked).
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static var isAvailable: Bool { function != nil }

    /// Asks the audio server to lower every *other* process on `device` to `level` (linear gain). 1.0 withdraws
    /// this process's request.
    @discardableResult
    static func request(_ device: AudioObjectID, level: Float32, ramp: Float32 = 0) -> OSStatus {
        guard let function else { return kAudioHardwareUnsupportedOperationError }
        return function(device, level, nil, ramp)
    }
}

/// Unified log (`log stream --predicate 'subsystem == "local.noduck"'`) and stderr, which the login agent sends to
/// ~/Library/Logs/NoDuck.log.
enum Log {
    private static let logger = Logger(subsystem: "local.noduck", category: "app")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(stamp.string(from: Date())) \(message)\n".utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(stamp.string(from: Date())) ERROR \(message)\n".utf8))
    }
}
