# mutewake

Mutes your Mac's audio output every time it sleeps, locks, wakes, or unlocks.

## Why

If you need speakers on for calls, it's easy to forget to mute before walking
into a lecture, a library, or a meeting — and then your laptop rings, or plays a
notification sound, in a quiet room.

Scheduling a mute doesn't really solve it: schedules change, classes get
cancelled, and a fixed timer will happily mute you in the middle of a call.
mutewake inverts the failure mode instead. Audio is muted whenever you close the
lid or wake the machine, and you unmute deliberately when you actually need
sound. The worst case becomes "a meeting starts silent for five seconds" rather
than "my phone rings during a lecture."

Muting at sleep matters as much as at wake: it means an incoming call can't ring
a laptop that's asleep in your bag.

## Install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/00mkp/mutewake.git
cd mutewake
./install.sh
```

The installer builds the daemon from source, generates a launchd agent for your
account, and starts it. It builds locally rather than shipping a binary so you
never hit Gatekeeper quarantine — and so you can read exactly what you're running.

## Usage

```
mutewake on           turn the feature on (starts the daemon)
mutewake off          turn it off (stops the daemon; survives reboot)
mutewake toggle       flip between on and off
mutewake status       feature state, daemon state, current audio, recent events
mutewake status -n N  same, showing the last N log entries (default 5)
mutewake uninstall    remove the daemon, agent, state, and logs
```

```
$ mutewake status
feature:  on
daemon:   running (pid 13958)
audio:    muted
recent:
  [2026-09-03 15:32:01] sleep: muted
  [2026-09-03 15:32:05] wake: already muted (muted while away)
```

To get sound back, tap the volume-up key. mutewake **mutes** rather than setting
the volume to zero, so your level is preserved.

## How it works

A small Swift agent subscribes to three events and sleeps in between — it polls
nothing and uses no measurable CPU:

| Event | Behavior |
| --- | --- |
| `willSleep` (lid close) | Mutes silently; nobody is looking at the screen |
| `screenIsLocked` | Same as sleep |
| `didWake` (lid open) | Mutes, and shows a banner |
| `screenIsUnlocked` | Same as wake |

Leaving (sleep, lock) mutes silently; returning (wake, unlock) shows the banner.
Locking earns its own trigger because a Mac can sit locked but awake — lid open,
on power — and nothing would mute it until you came back, leaving a window where
notifications play aloud.

Wake and unlock usually fire together on a lid-open, so events within five
seconds of each other are collapsed to avoid a duplicate banner. If the machine
was muted on the way out, the next return reports it — otherwise muting on leave
would leave nothing for the banner to say.

`mutewake off` writes a state file *and* stops the agent. The daemon re-checks
that file at startup and exits cleanly if it's set, and the agent is configured
with `KeepAlive: { SuccessfulExit: false }` so launchd won't respawn it. That
combination is what makes "off" survive a reboot with no process left running —
`launchctl bootout` alone would not, because launchd re-bootstraps user agents
at every login.

Everything it touches:

```
~/.local/bin/mutewake                          the CLI
~/.local/share/mutewake/mutewake.app           the daemon
~/Library/LaunchAgents/io.github.00mkp.mutewake.plist
~/.config/mutewake/disabled                    present only when off
~/Library/Logs/mutewake.log                    trimmed to 500 lines at startup
```

## Known limitation: banner attribution

The "Audio muted" banner is attributed to **Script Editor**, not to mutewake.

This isn't an oversight. macOS refuses to register an ad-hoc-signed,
non-notarized app with the notification center — `UNUserNotificationCenter`
returns `Notifications are not allowed for this application` and never shows a
permission prompt. Moving the bundle to `~/Applications`, launching it through
LaunchServices, `lsregister`, adding the full complement of `Info.plist` keys,
and embedding the plist in the binary all make no difference. Posting through
`osascript` works reliably, so that's what it does. Fixing the attribution
properly requires a paid Apple Developer ID.

## Testing

```sh
./test/verify.sh
```

Integration tests against the real launchd agent and real audio state: muting on
lock and unlock, debounce, the no-op path, `off` stopping the daemon, `off`
surviving a simulated reboot, toggle round-trips, and argument rejection. It toggles your actual audio
while running and leaves the feature on.

The sleep path isn't covered — `NSWorkspace` rejects externally posted
notifications, so `willSleep` can only be exercised by genuinely sleeping the
machine.

## Uninstall

```sh
mutewake uninstall
```

Removes the agent, daemon, state, logs, and the command itself. Your source
checkout is left alone.

## License

MIT — see [LICENSE](LICENSE).
