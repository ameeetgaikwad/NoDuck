import AppKit
import CoreAudio

/// The menu bar item and the decision loop. While a call is running (an app uses a microphone, or FaceTime's call
/// daemon is busy), plus a short grace period after it ends, other apps on the output device are protected.
final class Controller: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var enabledItem = menuItem("Keep Other Apps Loud During Calls", #selector(Controller.toggleEnabled))
    private lazy var faceTimeOnlyItem = menuItem("Only for FaceTime Calls", #selector(Controller.toggleFaceTimeOnly))
    private lazy var permissionItem = menuItem("Allow System Audio Recording…", #selector(Controller.fixPermission))

    private let monitor = AudioActivityMonitor()
    private var protector: Protector?
    private var lastCallSeen: Date?
    private var callNames: [String] = []
    private var lastBuild = Date.distantPast
    private var retryAfter = Date.distantPast
    private var lastError: String?
    private var evaluateScheduled = false
    private var timer: Timer?
    private var permissionCache: (date: Date, status: Permission.Status)?
    private var look: Look?
    private let ownPID = getpid()
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "local.noduck"
    private let defaults = UserDefaults.standard

    /// Call apps release and reopen the microphone around hang-up, so keep protecting a little longer than the call.
    private let gracePeriod: TimeInterval = 4
    /// Microphone users that aren't calls. Add more with
    /// `defaults write local.noduck IgnoredApps -array <bundle ID prefix or process name> ...`
    private let notCalls = ["com.apple.siri", "com.apple.assistant", "com.apple.corespeech", "com.apple.dictation",
                            "com.apple.SpeechRecognitionCore", "corespeechd", "assistantd", "SiriNCService",
                            "localspeechrecognition", "DictationIM", "speechrecognitiond"]

    private var enabled: Bool {
        get { defaults.object(forKey: "Enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "Enabled") }
    }

    private var faceTimeOnly: Bool {
        get { defaults.bool(forKey: "FaceTimeOnly") }
        set { defaults.set(newValue, forKey: "FaceTimeOnly") }
    }

    func start() {
        statusItem.autosaveName = "NoDuck"
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        detailLine.isEnabled = false
        detailLine.isHidden = true
        let quitItem = menuItem("Quit NoDuck", #selector(Controller.quit))
        quitItem.keyEquivalent = "q"
        [statusLine, detailLine, .separator(), enabledItem, faceTimeOnlyItem, permissionItem, .separator(),
         menuItem("Open Log", #selector(Controller.openLog)), quitItem].forEach(menu.addItem)
        statusItem.menu = menu

        if Permission.status() == .undetermined {
            Permission.request { [weak self] _ in self?.permissionChanged() }
        }
        monitor.onChange = { [weak self] in self?.scheduleEvaluate() }
        monitor.start()
        // Calls are noticed through the monitor; the timer ends the grace period and catches anything it missed.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.evaluate() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("started, pid \(ownPID), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        evaluate()
    }

    func shutdown() {
        stopProtecting()
    }

    private func evaluate() {
        guard enabled else { return idle(.off, "Off") }
        guard Duck.isAvailable else { return idle(.problem, "Can't work on this macOS (no AudioDeviceDuck)") }
        switch permission() {
        case .authorized: break
        case .denied: return idle(.off, "Needs System Audio Recording permission")
        case .undetermined: return idle(.off, "Waiting for System Audio Recording permission")
        case .unavailable: return idle(.problem, "Can't check System Audio Recording permission")
        }

        let processes = AudioProcess.all()
        if let other = otherUnducker(in: processes) {
            return idle(.problem, "Quit \(other) first: it does the same job, and the two would tap each other")
        }
        let calls = processes.filter(isCall)
        if !calls.isEmpty {
            lastCallSeen = Date()
            callNames = Set(calls.map(\.displayName)).sorted()
        }
        guard let lastCallSeen, Date().timeIntervalSince(lastCallSeen) < gracePeriod else {
            return idle(.waiting, faceTimeOnly ? "Waiting for a FaceTime call" : "Waiting for a call")
        }

        let device = outputDevice()
        guard device != CA.unknown else { return idle(.problem, "No output device") }
        let me = CA.processObject(for: ownPID)
        guard me != CA.unknown else { return idle(.problem, "Core Audio doesn't list NoDuck yet") }

        // Never tap a call (its echo canceller needs its own sound on time; that includes calls "Only for FaceTime
        // Calls" ignores) or NoDuck (the replay would loop back). VoiceOver isn't ducked, so it would only get the delay.
        let micUsers = processes.filter { $0.pid != ownPID && $0.isRunningInput && !isIgnored($0) }
        let families = Set((calls + micUsers).map(\.family)).union(["FaceTime"])
        var exclude = Set(processes.filter {
            families.contains($0.family) || $0.bundleID == ownBundleID || $0.bundleID.hasPrefix("com.apple.VoiceOver")
        }.map(\.object))
        exclude.insert(me)

        let headline = "\(callNames.joined(separator: ", ")) call: other apps stay loud"
        if let protector, protector.device == device, protector.isStillValid(),
           exclude.isSubset(of: protector.excluded) || protector.exclude(exclude) {
            if let trouble = trouble(with: protector, among: processes) {
                return fail(trouble, on: device, retryIn: 30)
            }
            return render(.active, headline, detail: "on \(protector.deviceName)")
        }

        // (Re)build, but not more than once a second (a device that keeps changing) or right after a failure. The
        // timer comes back every second; a short wait is worth an earlier look.
        let wait = max(lastBuild.timeIntervalSinceNow + 1, retryAfter.timeIntervalSinceNow)
        guard wait <= 0 else {
            if wait < 1 { scheduleEvaluate(after: wait) }
            return
        }
        stopProtecting()
        lastBuild = Date()
        do {
            let protector = try Protector(device: device, excluding: exclude)
            self.protector = protector
            lastError = nil
            render(.active, headline, detail: "on \(protector.deviceName)")
        } catch {
            fail("\(error)", on: device, retryIn: 3)
        }
    }

    /// Why a running Protector can't help, if it can't: the audio server refused its duck request, or its tap stays
    /// silent while other apps play. That most likely means the System Audio Recording permission isn't really there,
    /// and those apps are muted by the tap; better to give them back than to keep them silent for the whole call.
    private func trouble(with protector: Protector, among processes: [AudioProcess]) -> String? {
        if let status = protector.duckStatus, status != noErr {
            return "macOS refused NoDuck's duck request (\(CA.describe(status)))"
        }
        guard !protector.hasHeardSound, Date().timeIntervalSince(protector.startedAt) > 5 else { return nil }
        let othersPlaying = processes.contains { process in
            process.pid != ownPID && process.isRunningOutput && !protector.excluded.contains(process.object)
                && CA.objects(process.object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
                    .contains(protector.device)
        }
        guard othersPlaying else { return nil }
        return "other apps are playing, yet NoDuck receives only silence (paused players, or no System Audio Recording permission)"
    }

    private func fail(_ problem: String, on device: AudioObjectID, retryIn delay: TimeInterval) {
        stopProtecting()
        retryAfter = Date().addingTimeInterval(delay)
        if lastError != problem { Log.error("can't keep other apps loud on \(CA.name(device)): \(problem)") }
        lastError = problem
        render(.problem, "Can't keep other apps loud", detail: problem)
    }

    private func isCall(_ process: AudioProcess) -> Bool {
        guard process.pid != ownPID else { return false }
        // FaceTime also counts while its processes play: a ringing call, or a muted one, may not use the microphone.
        if process.isFaceTime { return process.isRunningInput || process.isRunningOutput }
        return !faceTimeOnly && process.isRunningInput && !isIgnored(process)
    }

    private func isIgnored(_ process: AudioProcess) -> Bool {
        let ignored = notCalls + (defaults.stringArray(forKey: "IgnoredApps") ?? [])
        return ignored.contains { entry in
            (!process.bundleID.isEmpty && process.bundleID.hasPrefix(entry))
                || entry.caseInsensitiveCompare(process.executable) == .orderedSame
        }
    }

    /// Apps doing the same job with a tap of their own: each would treat the other's tap as a call, and tap its replay.
    private let otherUnduckers = ["io.github.anegoda1995.shuttheduckoff": "ShutTheDuckOff",
                                  "dev.mrrockysl.duckaudio": "Unduck Pro"]

    private func otherUnducker(in processes: [AudioProcess]) -> String? {
        for process in processes where process.pid != ownPID {
            if let name = otherUnduckers.first(where: { process.bundleID.hasPrefix($0.key) })?.value { return name }
        }
        return nil
    }

    /// The default output, or the device whose UID is in the `Device` default (`defaults write local.noduck Device <uid>`).
    private func outputDevice() -> AudioObjectID {
        if let uid = defaults.string(forKey: "Device"), let device = CA.device(withUID: uid) { return device }
        return CA.defaultOutputDevice()
    }

    private func idle(_ look: Look, _ text: String) {
        stopProtecting()
        render(look, text)
    }

    private func stopProtecting() {
        protector?.stop()
        protector = nil
    }

    /// Cached for a few seconds: evaluate() runs at least once a second.
    private func permission() -> Permission.Status {
        if defaults.bool(forKey: "AssumePermission") { return .authorized }
        if let cache = permissionCache, Date().timeIntervalSince(cache.date) < 3 { return cache.status }
        let status = Permission.status()
        permissionCache = (Date(), status)
        return status
    }

    private func permissionChanged() {
        permissionCache = nil
        evaluate()
    }

    /// Bursts of Core Audio notifications become one evaluation.
    private func scheduleEvaluate(after delay: TimeInterval = 0.05) {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.evaluateScheduled = false
            self?.evaluate()
        }
    }

    // MARK: - Menu

    private enum Look {
        case waiting, active, off, problem

        var symbol: String {
            switch self {
            case .waiting: return "bird"
            case .active: return "bird.fill"
            case .off: return "speaker.slash"
            case .problem: return "exclamationmark.triangle"
            }
        }
    }

    private func render(_ newLook: Look, _ text: String, detail: String? = nil) {
        if statusLine.title != text {
            statusLine.title = text
            Log.info(detail.map { "\(text) (\($0))" } ?? text)
        }
        detailLine.title = detail ?? ""
        detailLine.isHidden = detail == nil
        enabledItem.state = enabled ? .on : .off
        faceTimeOnlyItem.state = faceTimeOnly ? .on : .off
        faceTimeOnlyItem.isEnabled = enabled
        permissionItem.isHidden = permission() == .authorized
        guard let button = statusItem.button else { return }
        button.toolTip = "NoDuck: \(text)"
        guard newLook != look else { return }
        look = newLook
        if let image = NSImage(systemSymbolName: newLook.symbol, accessibilityDescription: text) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "🦆"
        }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        evaluate()
    }

    @objc private func toggleFaceTimeOnly() {
        faceTimeOnly.toggle()
        evaluate()
    }

    @objc private func fixPermission() {
        if Permission.status() == .undetermined {
            Permission.request { [weak self] _ in self?.permissionChanged() }
        } else {
            Permission.openSettings()
        }
    }

    @objc private func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NoDuck.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            // Not started by the login agent: everything is in the unified log too.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        }
    }

    @objc private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }
}
