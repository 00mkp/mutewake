// Posts the screen-unlock notification that mutewake listens for, so the wake
// path can be exercised without physically locking the machine.
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.apple.screenIsUnlocked"), object: nil, deliverImmediately: true)
