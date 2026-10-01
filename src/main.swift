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
        ) { _ in menu.open() }

        let pid = ProcessInfo.processInfo.processIdentifier
        log(isDisabled() ? "daemon started (pid \(pid), feature off)" : "daemon started (pid \(pid))")
    }
}

let label = "io.github.00mkp.mutewake"
let reopenNotification = Notification.Name("\(label).reopen")

/// launchd owns the daemon: it starts it at login and keeps it alive. A copy
/// opened from Finder, Spotlight, or Launchpad would be a second, unmanaged
/// instance - so instead it asks launchd to start the real one (a no-op if it
/// is already up), tells that one to show its menu, and exits.
func handOff() -> Never {
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
    let domain = "gui/\(getuid())"
    if launchctl("kickstart", "\(domain)/\(label)") != 0 {
        // Not loaded at all (e.g. booted out): load the agent install.sh wrote.
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
        if launchctl("bootstrap", domain, plist) != 0 {
            log("opened outside launchd, but the agent could not be started; reinstall with install.sh")
        }
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
