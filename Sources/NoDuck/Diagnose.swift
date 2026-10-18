import CoreAudio
import Foundation

/// `NoDuck --diagnose`: prints what NoDuck sees. Run it during a call, with music playing, when something is off.
enum Diagnose {
    static func run() {
        print("NoDuck diagnostics, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("AudioDeviceDuck: \(Duck.isAvailable ? "available" : "MISSING (NoDuck can't work on this macOS)")")
        print("System Audio Recording permission of this process (Terminal's, when run from Terminal): \(Permission.status())")
        print("This process as a Core Audio process object: \(CA.processObject(for: getpid()))")

        let defaultOutput = CA.defaultOutputDevice()
        print("\nOutput devices (* = default):")
        for device in CA.devices() where CA.channelCount(device, kAudioObjectPropertyScopeOutput) > 0 {
            print("\(device == defaultOutput ? "*" : " ") [\(device)] \(CA.name(device))")
            print("      uid \(CA.deviceUID(device) ?? "?"), transport \(CA.fourCC(CA.transportType(device))), "
                  + "\(Int(CA.nominalSampleRate(device))) Hz, "
                  + "\(CA.channelCount(device, kAudioObjectPropertyScopeOutput)) out / "
                  + "\(CA.channelCount(device, kAudioObjectPropertyScopeInput)) in channels, "
                  + "\(CA.streams(device, kAudioObjectPropertyScopeInput).count) input stream(s)")
            // An undocumented per-device property; printed only to help work out what the audio server is doing.
            for (scopeName, scope) in [("global", kAudioObjectPropertyScopeGlobal), ("output", kAudioObjectPropertyScopeOutput)] {
                if let bytes = CA.bytes(device, CA.fourCC("duck"), scope: scope) {
                    print("      'duck' (\(scopeName)): \(describe(bytes))")
                }
            }
        }

        print("\nAudio processes (in = using a microphone, out = playing):")
        for process in AudioProcess.all().sorted(by: { $0.pid < $1.pid }) {
            let activity = (process.isRunningInput ? " in" : "") + (process.isRunningOutput ? " out" : "")
            let devices = CA.objects(process.object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
                .map(CA.name).joined(separator: ", ")
            let identity = process.bundleID.isEmpty ? process.executable : process.bundleID
            print("  [\(process.object)] pid \(process.pid) \(process.displayName)\(process.isFaceTime ? " (FaceTime)" : "")"
                  + " — \(identity)\(activity)" + (devices.isEmpty ? "" : " → \(devices)"))
        }
    }

    private static func describe(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        guard !bytes.isEmpty, bytes.count % 4 == 0 else { return hex }
        let floats = stride(from: 0, to: bytes.count, by: 4).map { offset -> String in
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return "\(Float32(bitPattern: bits))"
        }
        return "\(hex) (as Float32: \(floats.joined(separator: ", ")))"
    }
}
