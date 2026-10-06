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
    let before = isMuted()
    if before == true {
        log("\(reason): already muted")
        return
    }
    // Unknown is treated like unmuted: muting twice is harmless, missing a mute
    // is not.
    mute()
    let after = isMuted()
    mutedWhileAway = after == true
    // No banner here on purpose - nobody is looking at the screen.
    log("\(reason): " + outcome(before: before, after: after))
}

/// How a mute attempt went, worded so the log only claims what it could see.
/// `before == nil` means the first status check timed out, so audio may
/// already have been muted.
func outcome(before: Bool?, after: Bool?) -> String {
    switch after {
    case true?: return before == nil ? "muted (status check timed out)" : "muted"
    case nil: return "mute sent (couldn't confirm)"
    case false?: return "MUTE FAILED"
    }
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

    let before = isMuted()
    if before == true {
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
    let after = isMuted()
    log("\(reason): " + outcome(before: before, after: after))
    if after == true {
        // If the first check timed out, audio may have been muted all along, so
        // don't claim this wake is what muted it.
        notify(before == nil ? "Audio is muted." : "Audio muted on \(reason).")
    }
}
