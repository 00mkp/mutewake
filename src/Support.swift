import Foundation

// Paths, logging, and audio control shared by the event handlers and the menu.

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let stateDir = home.appendingPathComponent(".config/mutewake")
let stateFile = stateDir.appendingPathComponent("disabled")
let logFile = home.appendingPathComponent("Library/Logs/mutewake.log")

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
    as? String ?? "unknown"

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

/// The last `count` log entries, oldest first, with their timestamps parsed.
func recentLog(_ count: Int) -> [(date: Date?, message: String)] {
    guard let contents = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
    return contents.split(separator: "\n").suffix(count).map { line in
        // "[yyyy-MM-dd HH:mm:ss] message"
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else {
            return (nil, String(line))
        }
        let date = stamp.date(from: String(line[line.index(after: line.startIndex)..<close]))
        let message = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (date, message)
    }
}

// The flag file is the single source of truth for on/off, shared with the CLI.
// The daemon keeps running while it exists; it just stops acting on events.
func isDisabled() -> Bool {
    fm.fileExists(atPath: stateFile.path)
}

func setDisabled(_ disabled: Bool) {
    if disabled {
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        fm.createFile(atPath: stateFile.path, contents: nil)
    } else {
        try? fm.removeItem(at: stateFile)
    }
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
    // Everything calls this on the main thread, so a wedged osascript (say,
    // coreaudiod stuck mid device switch) would freeze the menu and every later
    // sleep/wake handler with it. Kill it rather than wait forever.
    let deadline = DispatchWorkItem {
        guard p.isRunning else { return }
        log("osascript timed out: \(script)")
        p.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    deadline.cancel()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func isMuted() -> Bool {
    osascript("output muted of (get volume settings)") == "true"
}

func mute() {
    osascript("set volume output muted true")
}

func unmute() {
    osascript("set volume output muted false")
}

/// Mute state and output volume in one osascript round trip (~100 ms), so the
/// menu can open without a visible stall. Nil when the output can't be read,
/// e.g. some external interfaces report "missing value".
func audioState() -> (muted: Bool, volume: Int)? {
    // "output volume:40, input volume:27, alert volume:100, output muted:false"
    var fields: [String: String] = [:]
    for pair in osascript("get volume settings").split(separator: ",") {
        let kv = pair.split(separator: ":", maxSplits: 1)
        guard kv.count == 2 else { continue }
        fields[kv[0].trimmingCharacters(in: .whitespaces)] =
            kv[1].trimmingCharacters(in: .whitespaces)
    }
    guard let muted = fields["output muted"], let volume = fields["output volume"].flatMap({ Int($0) })
    else { return nil }
    return (muted == "true", volume)
}

func notify(_ body: String) {
    // Banners are posted via osascript rather than UserNotifications: an ad-hoc
    // signed, non-notarized bundle cannot register with the notification center,
    // so UNUserNotificationCenter always returns "not allowed". The banner is
    // therefore attributed to Script Editor, but carries the mutewake title.
    let escaped = body.replacingOccurrences(of: "\"", with: "")
    osascript("display notification \"\(escaped)\" with title \"mutewake\"")
}
