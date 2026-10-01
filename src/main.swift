import AppKit
import Foundation

// mutewake daemon — mutes system output whenever the Mac sleeps, locks, wakes, or
// is unlocked, and shows its state in the menu bar.
// Controlled by the menu or by the `mutewake` CLI; see ~/.local/bin/mutewake.

final class Delegate: NSObject, NSApplicationDelegate {
    var menu: StatusMenu?
    var watcher: StateWatcher?

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

        let menu = StatusMenu()
        self.menu = menu
        watcher = StateWatcher { _ in menu.refreshIcon() }

        // Posted by a copy opened from Finder/Spotlight (see handOff below), so
        // opening the app while it's already running shows the menu.
        DistributedNotificationCenter.default().addObserver(
            forName: reopenNotification, object: nil, queue: .main
        ) { _ in
            try? fm.removeItem(at: openMenuMarker)
            menu.open()
        }
        // Started by a hand-opened copy: show the menu it asked for. The age
        // check keeps a marker left by some failed hand-off from popping the
        // menu at a later login.
        if let made = (try? fm.attributesOfItem(atPath: openMenuMarker.path))?[.creationDate] as? Date {
            try? fm.removeItem(at: openMenuMarker)
            if Date().timeIntervalSince(made) < 30 {
                DispatchQueue.main.async { menu.open() }
            }
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        log(isDisabled() ? "daemon started (pid \(pid), feature off)" : "daemon started (pid \(pid))")
    }
}

let label = "io.github.00mkp.mutewake"
let reopenNotification = Notification.Name("\(label).reopen")

// Left by a hand-opened copy so a daemon it just started shows its menu once up:
// the reopen notification alone would arrive before that daemon is listening.
let openMenuMarker = stateDir.appendingPathComponent("open-menu")

/// Explains why a hand-opened copy can't hand off, then exits. A copy opened
/// from Finder has no terminal, so a log line alone would look like nothing
/// happened at all.
func refuse(_ message: String, _ detail: String) -> Never {
    log("opened outside launchd: \(message)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = detail
    alert.runModal()
    exit(1)
}

/// launchd owns the daemon: it starts it at login and keeps it alive. A copy
/// opened from Finder, Spotlight, or Launchpad would be a second, unmanaged
/// instance - so instead it asks launchd to start the real one (a no-op if it
/// is already up), has that one show its menu, and exits.
func handOff() -> Never {
    let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    let reinstall = "Run ./install.sh from your mutewake checkout to set it up from here. "
        + "To keep the app somewhere other than ~/Applications, run it as APP_DIR=<folder> ./install.sh."

    // The agent runs whatever path install.sh wrote into it. If this copy is
    // somewhere else - dragged to /Applications in Finder, say - starting the
    // agent would run a binary that is gone, or not this one.
    guard let agent = NSDictionary(contentsOf: plist),
          let registered = (agent["ProgramArguments"] as? [String])?.first else {
        refuse("mutewake isn't installed", reinstall)
    }
    let mine = Bundle.main.executableURL?.resolvingSymlinksInPath().path
    if URL(fileURLWithPath: registered).resolvingSymlinksInPath().path != mine {
        // Name the app, not the binary inside it: ".../mutewake.app".
        let bundle = URL(fileURLWithPath: registered)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        refuse("mutewake was moved", "It's set up to run from \(bundle.path). " + reinstall)
    }


    func launchctl(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
    fm.createFile(atPath: openMenuMarker.path, contents: nil)
    let domain = "gui/\(getuid())"
    if launchctl("kickstart", "\(domain)/\(label)") != 0,
       // Not loaded at all (e.g. booted out): load the agent install.sh wrote.
       launchctl("bootstrap", domain, plist.path) != 0 {
        try? fm.removeItem(at: openMenuMarker)
        refuse("mutewake couldn't start", reinstall)
    }
    DistributedNotificationCenter.default().postNotificationName(
        reopenNotification, object: nil, deliverImmediately: true)
    exit(0)
}

// launchd sets XPC_SERVICE_NAME to the job's label; anything else (an app opened
// from Finder gets "application.<bundle id>...") is a hand-launched copy.
if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != label {
    handOff()
}

trimLog()

// Unlike earlier versions, the daemon stays up while the feature is off: the menu
// bar item has to survive "off" so it can turn the feature back on. The flag file
// still persists across reboots, and every handler checks it, so "off" still
// means nothing gets muted.
let delegate = Delegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
