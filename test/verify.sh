#!/bin/zsh
# Integration tests for mutewake. Requires mutewake to be installed (./install.sh).
# Toggles your real audio and the real launchd agent, and leaves the feature ON.
#
# The sleep path is deliberately not covered: NSWorkspace rejects externally
# posted notifications, so willSleep can only be exercised by a real sleep.
LABEL="io.github.00mkp.mutewake"; DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"; LOG="$HOME/Library/Logs/mutewake.log"
POST="${0:A:h}/post_unlock.swift"
LOCK="${0:A:h}/post_lock.swift"
pass=0; fail=0
check() { if eval "$2"; then print "  PASS  $1"; ((pass++)); else print "  FAIL  $1"; ((fail++)); fi }
pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk -F'= ' '/^\tpid = /{print $2; exit}' }
muted() { [[ "$(osascript -e 'output muted of (get volume settings)')" == "true" ]] }

: > "$LOG"
print "\\n[1] enable + mute on unlock event"
osascript -e 'set volume output muted false'
mutewake on >/dev/null; sleep 1
check "daemon is running" '[[ -n "$(pid)" ]]'
check "audio starts unmuted" '! muted'
swift "$POST"; sleep 2
check "audio muted after unlock event" 'muted'
check "log records the mute" 'grep -q "unlock: muted" "$LOG"'

print "\\n[2] lock mutes silently, unlock reports it"
osascript -e 'set volume output muted false'
sleep 5; swift "$LOCK"; sleep 2
check "audio muted on lock" 'muted'
check "lock logged as its own event" 'grep -q "lock: muted" "$LOG"'
sleep 5; swift "$POST"; sleep 2
check "unlock reports it was muted while away" 'grep -q "already muted (muted while away)" "$LOG"'

print "\\n[3] debounce collapses a duplicate event"
osascript -e 'set volume output muted false'
swift "$POST"; sleep 1
check "second event within 5s is debounced" 'grep -q "skipped (debounce)" "$LOG"'

print "\\n[4] already-muted event is a no-op"
osascript -e 'set volume output muted true'
sleep 5; swift "$POST"; sleep 2
check "logs already-muted rather than re-muting" 'grep -q "already muted" "$LOG"'

print "\\n[5] off stops the daemon"
mutewake off >/dev/null; sleep 1
check "daemon stopped" '[[ -z "$(pid)" ]]'
check "state file written" '[[ -f "$HOME/.config/mutewake/disabled" ]]'

print "\\n[6] off survives a reboot (simulated re-bootstrap)"
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; sleep 3
check "daemon exits itself when disabled" '[[ -z "$(pid)" ]]'
check "log explains the clean exit" 'grep -q "disabled, exiting" "$LOG"'

print "\\n[7] while off, a wake event does nothing"
osascript -e 'set volume output muted false'
swift "$POST"; sleep 2
check "audio stays unmuted while off" '! muted'

print "\\n[8] toggle round-trip"
mutewake toggle >/dev/null; sleep 1
check "toggle turned it on" '[[ -n "$(pid)" && ! -f "$HOME/.config/mutewake/disabled" ]]'
mutewake toggle >/dev/null; sleep 1
check "toggle turned it off" '[[ -z "$(pid)" && -f "$HOME/.config/mutewake/disabled" ]]'

print "\\n[9] unknown command is rejected"
mutewake bogus >/dev/null 2>&1
check "exits non-zero on bad command" '[[ $? -ne 0 ]]'

print "\\n[10] update rejects bad input (no side effects)"
mutewake update /nope/missing >/dev/null 2>&1
check "rejects a missing path" '[[ $? -ne 0 ]]'
print "irrelevant" > "$TMPDIR/mw-notes.txt"
mutewake update "$TMPDIR/mw-notes.txt" >/dev/null 2>&1
check "rejects an unsupported archive type" '[[ $? -ne 0 ]]'
mutewake update "$TMPDIR" >/dev/null 2>&1
check "rejects a directory that is not a source tree" '[[ $? -ne 0 ]]'
rm -f "$TMPDIR/mw-notes.txt"

mutewake on >/dev/null
print "\n----- $pass passed, $fail failed -----"
[[ $fail -eq 0 ]]
