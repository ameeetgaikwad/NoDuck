import AppKit
import CoreAudio

/// One client of the audio server (a macOS 14+ process object).
struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    /// Full path of the executable, "" if unknown.
    let path: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var executable: String { (path as NSString).lastPathComponent }

    /// Every process the audio server knows about.
    static func all() -> [AudioProcess] {
        let objects = CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList)
        identities = identities.filter { objects.contains($0.key) }
        return objects.map(AudioProcess.init(object:))
    }

    /// A process object's PID, bundle ID and path never change, so they are read once.
    private struct Identity { let pid: pid_t; let bundleID: String; let path: String }
    private static var identities: [AudioObjectID: Identity] = [:]

    private init(object: AudioObjectID) {
        let identity = Self.identities[object] ?? {
            let pid = CA.value(object, kAudioProcessPropertyPID, pid_t(-1))
            let identity = Identity(pid: pid, bundleID: CA.string(object, kAudioProcessPropertyBundleID) ?? "",
                                    path: Self.executablePath(pid))
            // A failed read is tried again next time instead of being remembered.
            if pid > 0 && !(identity.bundleID.isEmpty && identity.path.isEmpty) { Self.identities[object] = identity }
            return identity
        }()
        self.object = object
        pid = identity.pid
        bundleID = identity.bundleID
        path = identity.path
        isRunningInput = CA.value(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0
        isRunningOutput = CA.value(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
    }

    private static func executablePath(_ pid: pid_t) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// FaceTime calls (and SharePlay, and iPhone calls relayed to the Mac) run in system daemons, not in FaceTime.app.
    private static let faceTimeExecutables: Set<String> = ["avconferenced", "callservicesd", "FaceTime"]
    private static let faceTimeBundlePrefixes = ["com.apple.avconferenced", "com.apple.FaceTime",
                                                 "com.apple.telephonyutilities.callservicesd"]

    var isFaceTime: Bool {
        Self.faceTimeExecutables.contains(executable) || Self.faceTimeBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Processes of the same app: the outermost .app bundle, so browser and Electron helpers count as their app.
    /// All of FaceTime's processes are one family; any other daemon is a family of its own.
    var family: String {
        if isFaceTime { return "FaceTime" }
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        return bundleID.isEmpty ? executable : bundleID
    }

    var displayName: String {
        if isFaceTime { return "FaceTime" }
        if family.hasSuffix(".app") { return ((family as NSString).lastPathComponent as NSString).deletingPathExtension }
        return executable.isEmpty ? "pid \(pid)" : executable
    }
}

/// Calls `onChange` on the main queue whenever audio activity may have changed: a process starts or stops audio, a
/// microphone starts or stops, devices, the default output or an output's format change. The audio server sends no
/// notification for kAudioProcessPropertyIsRunningInput itself, but these arrive in time; the controller's timer
/// catches anything else.
final class AudioActivityMonitor {
    var onChange: (() -> Void)?
    private var watched = Set<AudioObjectID>()

    func start() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices] {
            listen(CA.system, selector, refresh: true)
        }
        listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice)
        refresh()
    }

    /// Listeners go away together with their objects, so only objects not seen before need one.
    private func refresh() {
        let processes = CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList)
        let devices = CA.devices()
        for process in processes where !watched.contains(process) {
            for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningInput,
                             kAudioProcessPropertyIsRunningOutput] {
                listen(process, selector)
            }
        }
        for device in devices where !watched.contains(device) {
            if !CA.streams(device, kAudioObjectPropertyScopeInput).isEmpty {
                listen(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
            }
            if !CA.streams(device, kAudioObjectPropertyScopeOutput).isEmpty {
                listen(device, kAudioDevicePropertyNominalSampleRate)
                listen(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
            }
        }
        watched = Set(processes + devices)
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, refresh: Bool = false) {
        var address = CA.address(selector, scope)
        AudioObjectAddPropertyListenerBlock(object, &address, .main) { [weak self] _, _ in
            guard let self else { return }
            if refresh { self.refresh() }
            self.onChange?()
        }
    }
}
