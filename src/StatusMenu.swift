import AppKit

// The menu bar item. A plain NSMenu on purpose: it is the system menu, so light
// and dark mode, accessibility, and keyboard navigation all come for free.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let on = !isDisabled()
        let label = on ? "mutewake: on" : "mutewake: off"
        let image = NSImage(systemSymbolName: on ? "speaker.slash.fill" : "speaker.slash",
                            accessibilityDescription: label)
        image?.isTemplate = true
        item.button?.image = image
        // Dimmed the same way the system dims its own inactive menu bar extras.
        item.button?.appearsDisabled = !on
        item.button?.toolTip = label
    }

    // Rebuilt on every open, so everything shown is current without any timers.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = !isDisabled()

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(
            string: on ? "mutewake is On" : "mutewake is Off",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        title.isEnabled = false
        menu.addItem(title)

        let audio = audioState()
        menu.addItem(info(audio.map {
            $0.muted ? "Audio: Muted" : "Audio: On — volume \($0.volume)%"
        } ?? "Audio: Unknown"))

        menu.addItem(.separator())
        menu.addItem(action(on ? "Turn Off" : "Turn On", #selector(toggle), key: "t"))
        if audio?.muted == true {
            menu.addItem(action("Unmute Now", #selector(unmuteNow), key: "u"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Recent Activity"))
        let entries = recentLog(5).reversed()
        if entries.isEmpty {
            menu.addItem(info("No activity yet"))
        }
        for entry in entries {
            menu.addItem(activityRow(entry.date, entry.message))
        }
        menu.addItem(action("Open Log…", #selector(openLog)))

        menu.addItem(.separator())
        menu.addItem(action("About mutewake", #selector(about)))
        menu.addItem(action("Quit mutewake", #selector(quit), key: "q"))
    }

    // MARK: - Actions

    // Writes the flag directly, exactly as the CLI does. The state watcher sees
    // the change, logs it, and refreshes the icon - one path for both front ends.
    @objc private func toggle() {
        setDisabled(!isDisabled())
    }

    @objc private func unmuteNow() {
        unmute()
        log("unmuted from menu")
    }

    @objc private func openLog() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([logFile], withApplicationAt: console,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func about() {
        let icon = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "mutewake",
            .applicationVersion: appVersion,
            .version: "",
            .credits: NSAttributedString(
                string: "Mutes your Mac when it sleeps, locks, wakes, or unlocks.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]),
        ]
        if let icon { options[.applicationIcon] = icon }
        // An accessory app has to activate itself or the panel opens behind
        // whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    // Exit 0: the agent is KeepAlive only on unsuccessful exit, so launchd leaves
    // it down until the next login or `mutewake on`.
    @objc private func quit() {
        log("quit from menu")
        NSApp.terminate(nil)
    }

    // MARK: - Item builders

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return .sectionHeader(title: title) }
        return info(title)
    }

    private func activityRow(_ date: Date?, _ message: String) -> NSMenuItem {
        let text = NSMutableAttributedString(string: describe(message),
                                             attributes: [.foregroundColor: NSColor.labelColor])
        if let date {
            let ago = Date().timeIntervalSince(date) < 60
                ? "just now" : relative.localizedString(for: date, relativeTo: Date())
            text.append(NSAttributedString(string: "  ·  \(ago)",
                                           attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        let item = info("")
        item.attributedTitle = text
        item.indentationLevel = 1
        return item
    }

    /// Turns a raw log line ("wake: already muted (muted while away)") into
    /// something readable ("Already muted on wake"). Unknown lines pass through.
    private func describe(_ message: String) -> String {
        switch message {
        case "feature: on": return "Turned on"
        case "feature: off": return "Turned off"
        case "unmuted from menu": return "Unmuted from menu"
        case "quit from menu": return "Quit"
        default: break
        }
        if message.hasPrefix("daemon start") { return "Started" }

        let parts = message.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return message }
        let event = String(parts[0])
        let outcome = parts[1].trimmingCharacters(in: .whitespaces)
        switch outcome {
        case "muted": return "Muted on \(event)"
        case "MUTE FAILED": return "Mute failed on \(event)"
        case "skipped (disabled)": return "Ignored \(event) (off)"
        case "skipped (debounce)": return "Ignored duplicate \(event)"
        case _ where outcome.hasPrefix("already muted"): return "Already muted on \(event)"
        default: return message
        }
    }
}
