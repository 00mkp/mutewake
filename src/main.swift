import AppKit
import Foundation

// mutewake daemon — mutes system output whenever the Mac wakes or is unlocked.
// Controlled by the `mutewake` CLI; see ~/.local/bin/mutewake.

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let stateFile = home.appendingPathComponent(".config/mutewake/disabled")
let logFile = home.appendingPathComponent("Library/Logs/mutewake.log")

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "[\(stamp.string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logFile) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? data.write(to: logFile)
    }
}

// The log is append-only and would otherwise grow without bound. Startup is the
// natural place to trim it: it happens at every login and costs nothing.
let logCap = 500

func trimLog() {
    guard let contents = try? String(contentsOf: logFile, encoding: .utf8) else { return }
    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    guard lines.count > logCap else { return }
    let kept = lines.suffix(logCap).joined(separator: "\n") + "\n"
    try? kept.write(to: logFile, atomically: true, encoding: .utf8)
}

func isDisabled() -> Bool {
    fm.fileExists(atPath: stateFile.path)
}

@discardableResult
func osascript(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do {
        try p.run()
    } catch {
        log("osascript launch failed: \(error.localizedDescription)")
        return ""
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func isMuted() -> Bool {
    osascript("output muted of (get volume settings)") == "true"
}

func mute() {
    osascript("set volume output muted true")
}

func notify(_ body: String) {
    // Banners are posted via osascript rather than UserNotifications: an ad-hoc
    // signed, non-notarized bundle cannot register with the notification center,
    // so UNUserNotificationCenter always returns "not allowed". The banner is
    // therefore attributed to Script Editor, but carries the mutewake title.
    let escaped = body.replacingOccurrences(of: "\"", with: "")
    osascript("display notification \"\(escaped)\" with title \"mutewake\"")
}

// Wake and unlock often fire together on a lid-open; collapse them into one event.
// Sleep is deliberately exempt: it should never suppress the wake that follows it.
var lastAction = Date.distantPast
let debounce: TimeInterval = 5

// Set when we mute on the way out, so the next return can tell you it happened.
// Without this you would never see a banner: leaving would mute, and coming back
// would find the machine already muted and stay silent.
var mutedWhileAway = false

// Going away: sleeping, or locking the screen. Locking matters on its own because
// a Mac can sit locked but awake - lid open, on power - and nothing would mute it
// until you came back, leaving a whole window where notifications play aloud.
func handleAway(_ reason: String) {
    if isDisabled() {
        log("\(reason): skipped (disabled)")
        return
    }
    if isMuted() {
        log("\(reason): already muted")
        return
    }
    mute()
    mutedWhileAway = isMuted()
    // No banner here on purpose - nobody is looking at the screen.
    log(mutedWhileAway ? "\(reason): muted" : "\(reason): MUTE FAILED")
}

func handleWake(_ reason: String) {
    if isDisabled() {
        log("\(reason): skipped (disabled)")
        return
    }
    let now = Date()
    if now.timeIntervalSince(lastAction) < debounce {
        log("\(reason): skipped (debounce)")
        return
    }
    lastAction = now

    if isMuted() {
        if mutedWhileAway {
            mutedWhileAway = false
            log("\(reason): already muted (muted while away)")
            notify("Audio was muted while you were away.")
        } else {
            log("\(reason): already muted")
        }
        return
    }
    mute()
    mutedWhileAway = false
    if isMuted() {
        log("\(reason): muted")
        notify("Audio muted on \(reason).")
    } else {
        log("\(reason): MUTE FAILED")
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in handleAway("sleep") }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in handleAway("lock") }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in handleWake("wake") }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in handleWake("unlock") }

        log("daemon started (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

}

trimLog()

// If the feature is switched off, exit cleanly. KeepAlive is SuccessfulExit=false,
// so launchd will not respawn us — `off` therefore survives a reboot.
if isDisabled() {
    log("daemon start: disabled, exiting")
    exit(0)
}

let delegate = Delegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
