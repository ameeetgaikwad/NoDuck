import AppKit

/// The "System Audio Recording Only" permission (TCC service kTCCServiceAudioCapture) that process taps need.
///
/// macOS has no public API to check or request it, and creating a tap does not show the prompt, so this talks to the
/// private TCC framework (as Apple's AudioCap-style samples do). Without the permission a tap delivers silence, so
/// NoDuck taps nothing until this reports `.authorized`.
enum Permission {
    enum Status { case authorized, denied, undetermined, unavailable }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static func status() -> Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unavailable }
        switch unsafeBitCast(symbol, to: PreflightFunction.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. `completion` runs on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: RequestFunction.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
