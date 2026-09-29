import Foundation

// What happens on sleep, lock, wake, and unlock.

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
