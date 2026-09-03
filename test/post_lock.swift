import Foundation
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.apple.screenIsLocked"), object: nil, deliverImmediately: true)
