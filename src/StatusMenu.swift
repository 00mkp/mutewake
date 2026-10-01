import AppKit

// The menu bar item. A plain NSMenu on purpose: it is the system menu, so light
// and dark mode, accessibility, and keyboard navigation all come for free.
final class StatusMenu: NSObject, NSMenuDelegate {
    // A sleeping speaker rather than a plain mute glyph: it reads as "audio +
    // sleep", and doesn't blend in with the system's own volume controls. The
    // app icon (tools/make-icon.swift) draws the same symbol; keep them in step.
    static let symbolOn = "speaker.zzz.fill"
    static let symbolOff = "speaker.zzz"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()

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
        let image = NSImage(systemSymbolName: on ? Self.symbolOn : Self.symbolOff,
                            accessibilityDescription: label)
        image?.isTemplate = true
        item.button?.image = image
        // Dimmed the same way the system dims its own inactive menu bar extras.
        item.button?.appearsDisabled = !on
        item.button?.toolTip = label
    }

    /// Pops the menu open, as if the icon had been clicked.
    func open() {
        item.button?.performClick(nil)
    }

    // Rebuilt on every open, so everything shown is current without any timers.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = !isDisabled()

        menu.addItem(row(InfoRow(title: "mutewake", detail: on ? "On" : "Off",
                                 bold: true, dot: on ? .systemGreen : .tertiaryLabelColor)))
        let audio = audioState()
        menu.addItem(row(InfoRow(title: "Audio", detail: audio.map {
            $0.muted ? "Muted" : "\($0.volume)%"
        } ?? "Unknown")))

        menu.addItem(.separator())
        menu.addItem(action(on ? "Turn Off" : "Turn On", #selector(toggle), key: "t"))
        // Mute rather than zero the volume, so unmuting brings back whatever level
        // you had. Hidden when the output can't be read.
        if let audio {
            menu.addItem(audio.muted
                ? action("Unmute Now", #selector(unmuteNow), key: "u")
                : action("Mute Now", #selector(muteNow), key: "m"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Recent Activity"))
        let entries = recentLog(5).reversed()
        if entries.isEmpty {
            menu.addItem(row(InfoRow(title: "No activity yet", detail: "", secondary: true)))
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

    @objc private func muteNow() {
        mute()
        log("muted from menu")
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
        // No icon option: the panel shows the bundle's app icon, the same one
        // Finder and Launchpad show.
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "mutewake",
            .applicationVersion: appVersion,
            .version: "",
            .credits: NSAttributedString(
                string: "Mutes your Mac when it sleeps, locks, wakes, or unlocks.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]),
        ]
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

    // Read-only rows are custom views, not disabled items: NSMenu draws every
    // disabled item greyed out whatever its attributed colors say, which made
    // the status and activity hard to read.
    private func row(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func activityRow(_ date: Date?, _ message: String) -> NSMenuItem {
        var ago = ""
        if let date {
            ago = Date().timeIntervalSince(date) < 60
                ? "just now" : relative.localizedString(for: date, relativeTo: Date())
        }
        return row(InfoRow(title: describe(message), detail: ago))
    }

    /// Turns a raw log line ("wake: already muted (muted while away)") into
    /// something readable ("Already muted on wake"). Unknown lines pass through.
    private func describe(_ message: String) -> String {
        switch message {
        case "feature: on": return "Turned on"
        case "feature: off": return "Turned off"
        case "muted from menu": return "Muted from menu"
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

/// A non-interactive menu row: a title on the left, a secondary detail pinned to
/// the right, and an optional status dot. Laid out to line up with the text of
/// ordinary menu items.
final class InfoRow: NSView {
    // Where NSMenu starts an item's title, and the trailing gutter it leaves
    // before key equivalents.
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 14

    init(title: String, detail: String, bold: Bool = false,
         secondary: Bool = false, dot: NSColor? = nil) {
        let font = NSFont.menuFont(ofSize: 0)
        let left = NSTextField(labelWithString: title)
        left.font = bold ? NSFont.boldSystemFont(ofSize: font.pointSize) : font
        left.textColor = secondary ? .secondaryLabelColor : .labelColor
        let right = NSTextField(labelWithString: detail)
        right.font = font
        right.textColor = .secondaryLabelColor
        right.alignment = .right

        var dotView: NSView?
        if let dot {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = dot.cgColor
            v.layer?.cornerRadius = 3.5
            dotView = v
        }

        left.sizeToFit()
        right.sizeToFit()
        let height: CGFloat = 22
        let dotSpace: CGFloat = dotView == nil ? 0 : 13
        let width = Self.leading + left.frame.width + 24 + dotSpace + right.frame.width + Self.trailing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]

        let y = ((height - left.frame.height) / 2).rounded()
        left.frame.origin = NSPoint(x: Self.leading, y: y)
        right.frame.origin = NSPoint(x: width - Self.trailing - right.frame.width, y: y)
        right.autoresizingMask = [.minXMargin]
        addSubview(left)
        addSubview(right)
        if let dotView {
            dotView.frame = NSRect(x: right.frame.minX - 12, y: (height - 7) / 2, width: 7, height: 7)
            dotView.autoresizingMask = [.minXMargin]
            addSubview(dotView)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
