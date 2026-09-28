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

        let pid = ProcessInfo.processInfo.processIdentifier
        log(isDisabled() ? "daemon started (pid \(pid), feature off)" : "daemon started (pid \(pid))")
    }
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
