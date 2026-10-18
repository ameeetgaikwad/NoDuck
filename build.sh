#!/bin/bash
# Builds NoDuck.app with the Xcode Command Line Tools (xcode-select --install) and installs it as a login item.
#
#   ./build.sh             build build/NoDuck.app
#   ./build.sh run         build and start it once, without installing
#   ./build.sh install     build, copy to /Applications, start it now and at every login
#   ./build.sh uninstall   remove the app, the login agent, its settings and its permission
set -euo pipefail
cd "$(dirname "$0")"

APP=NoDuck
ID=local.noduck
BUNDLE="build/$APP.app"
DEST="${DEST:-/Applications}"
AGENT="$HOME/Library/LaunchAgents/$ID.plist"
LOG="$HOME/Library/Logs/$APP.log"
DOMAIN="gui/$(id -u)"

build() {
    if ! command -v swift >/dev/null; then
        echo "Swift is missing. Install the Command Line Tools with: xcode-select --install" >&2
        exit 1
    fi
    swift build -c release
    local bin
    bin="$(swift build -c release --show-bin-path)/$APP"
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS"
    cp "$bin" "$BUNDLE/Contents/MacOS/$APP"
    cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
    codesign --force --sign - --identifier "$ID" "$BUNDLE"
    echo "Built $BUNDLE"
}

stop_running() {
    launchctl bootout "$DOMAIN/$ID" 2>/dev/null || true
    pkill -x "$APP" 2>/dev/null || true
    # A new copy started while the old one is still exiting would find it running and quit.
    for _ in $(seq 20); do
        pgrep -x "$APP" >/dev/null || break
        sleep 0.1
    done
}

# Every build gets a new ad-hoc signature, which macOS treats as a new app. Clear the old permission entry so the
# prompt comes back instead of a silent denial.
reset_permission() {
    if ! tccutil reset AudioCapture "$ID" >/dev/null 2>&1; then
        echo "Note: couldn't reset the old System Audio Recording entry. If NoDuck says the permission is missing," >&2
        echo "turn it off and on in System Settings > Privacy & Security > Screen & System Audio Recording." >&2
    fi
}

install_app() {
    build
    stop_running
    rm -rf "${DEST:?}/$APP.app"
    cp -R "$BUNDLE" "$DEST/"
    reset_permission
    mkdir -p "$(dirname "$AGENT")" "$(dirname "$LOG")"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$ID</string>
    <key>AssociatedBundleIdentifiers</key>
    <string>$ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/$APP.app/Contents/MacOS/$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST
    # Right after a bootout, launchd can refuse for a moment ("Bootstrap failed: 5").
    for _ in 1 2 3 4 5; do
        launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null && break
        sleep 1
    done
    if ! launchctl print "$DOMAIN/$ID" >/dev/null 2>&1; then
        echo "Installed $DEST/$APP.app, but couldn't start the login agent. Try: launchctl bootstrap $DOMAIN $AGENT" >&2
        exit 1
    fi
    echo "Installed $DEST/$APP.app. It runs now and at every login (look for the bird in the menu bar)."
    echo "When macOS asks, allow System Audio Recording for NoDuck."
}

uninstall_app() {
    # On SIGTERM NoDuck stops cleanly; even if it were killed, macOS gives every app its sound back.
    stop_running
    rm -f "$AGENT"
    rm -rf "${DEST:?}/$APP.app"
    defaults delete "$ID" 2>/dev/null || true
    reset_permission
    echo "Uninstalled. The log is still at $LOG."
}

case "${1:-build}" in
    build) build ;;
    run)
        build
        stop_running
        reset_permission
        open "$BUNDLE"
        echo "Started $BUNDLE. (An installed copy was stopped; it starts again at the next login.)"
        ;;
    install) install_app ;;
    uninstall) uninstall_app ;;
    *) echo "usage: $0 [build|run|install|uninstall]" >&2; exit 1 ;;
esac
