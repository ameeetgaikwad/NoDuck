import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--diagnose") {
    Diagnose.run()
    exit(0)
}

// Two copies would tap each other's replay. The lock goes away with the process.
let instanceLock = open(NSTemporaryDirectory() + "local.noduck.lock", O_CREAT | O_RDWR, 0o600)
if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    Log.info("NoDuck is already running")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()

// launchd stops the login agent with SIGTERM (logout, uninstall); Ctrl-C when started from a terminal.
let signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        controller.shutdown()
        exit(0)
    }
    source.resume()
    return source
}
_ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    controller.shutdown()
}

controller.start()
app.run()
