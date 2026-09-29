# Menu bar item — design

Date: 2026-09-28 · Target version: 0.3.0

## Goal

Give mutewake a native macOS menu bar item that shows its state and offers the
common controls, so it is usable without a terminal. The CLI stays and remains
fully equivalent; the menu is an additional front end, not a replacement.

## Decisions

- **The daemon hosts the menu bar item.** It is already an accessory
  `NSApplication`; adding an `NSStatusItem` needs no second process or bundle.
- **"Off" becomes a flag, not a stopped process.** The icon must survive "off"
  so the menu can turn the feature back on. The flag file
  `~/.config/mutewake/disabled` remains the single source of truth.
  - The daemon always stays running; while the flag exists it ignores
    sleep/lock/wake/unlock (the per-event `isDisabled()` check already exists).
  - Reboot semantics are preserved: the flag persists, so after login the
    daemon starts, sees the flag, and sits idle with the "off" icon. Nothing is
    muted. The only cost is an idle process (no polling) while off.
- **Native `NSMenu`, not a SwiftUI popover.** It is the system menu, so light
  and dark mode, accessibility and keyboard navigation come for free.

## Behavior

### Daemon

- No longer exits at startup when disabled.
- Watches `~/.config/mutewake/` with a `DispatchSource` vnode source, and
  refreshes the icon when the flag appears or disappears. This is how a
  `mutewake on|off` from the terminal reaches the menu. The watcher re-arms
  itself if the directory is replaced.
- **Quit** calls `exit(0)`. The agent's `KeepAlive: { SuccessfulExit: false }`
  means launchd does not respawn it until the next login or `mutewake on`.

### CLI

- `mutewake off`: writes the flag, leaves the daemon running.
- `mutewake on`: removes the flag. If the daemon is not running (after Quit, or
  a crash), bootstraps or kickstarts it. If it is running, it does nothing
  more, because the watcher picks up the change.
- `mutewake status`: the daemon line reads `running (pid N)` when on,
  `running (pid N, idle — feature off)` when off, and `not running` when quit.
- `toggle`, `update`, `uninstall`: unchanged in interface.

### Menu

Icon: SF Symbol template image, a sleeping speaker:
`speaker.zzz.fill` when on, `speaker.zzz` dimmed when off. It gets an accessibility
description ("mutewake: on" / "mutewake: off").

```
mutewake                   ● On    (status row; green dot when on)
Audio                     Muted    (or the volume, e.g. "40%")
─────────
Turn Off                  ⌘T       (toggles to "Turn On")
Mute Now / Unmute Now     ⌘M/⌘U    (flips with the current audio state)
─────────
Recent Activity                    (section header)
Muted on sleep       2 min. ago    (last 5 log entries)
Open Log…                          (opens the log in Console)
─────────
About mutewake                     (standard About panel)
Quit mutewake             ⌘Q
```

Read-only rows (status, audio, activity) are custom `NSMenuItem.view`s rather
than disabled items: NSMenu greys out every disabled item regardless of its
attributed colors, which made them hard to read. The views align with the
title and key-equivalent columns of ordinary items.

- The menu is rebuilt in `menuNeedsUpdate(_:)`, so it is fresh on every open
  with no timers.
- Turn On/Off from the menu writes or removes the flag file directly, the same
  as the CLI. The daemon never shells out to the CLI.
- Mute Now / Unmute Now toggle the output mute flag through osascript; the
  volume level is untouched, so unmuting restores it.
- If the log is missing or empty, Recent Activity shows "No activity yet".

## Code structure

`src/` is split into focused files, compiled together by `swiftc src/*.swift`:

| File | Responsibility |
| --- | --- |
| `Support.swift` | paths, logging, log trim, osascript, mute/unmute/isMuted |
| `Events.swift` | sleep/lock/wake/unlock handlers (logic unchanged) |
| `StateWatcher.swift` | watches the config dir, calls back on flag change |
| `StatusMenu.swift` | `NSStatusItem` + `NSMenu` construction and actions |
| `main.swift` | app delegate, observers, startup |

`install.sh` compiles `src/*.swift`. The `update` sanity check still looks for
`src/main.swift`, which continues to exist.

## Testing

`test/verify.sh` is updated:

- `off` leaves the daemon running and writes the flag.
- A simulated re-bootstrap while off leaves the daemon running and idle, and the
  log records it as started disabled.
- Wake events while off do not mute.
- `toggle` round-trips the flag with the daemon staying up.
- After the daemon is stopped externally (simulating Quit), `mutewake on`
  starts it again.
- The running daemon logs flag changes made by the CLI, which proves the watcher
  works.

The menu's visual presentation is verified by hand in the running app.

## Out of scope

Per-trigger settings (for example, lock but not sleep), a launch-at-login toggle
(launchd already handles it), notarized distribution, and a SwiftUI popover.
