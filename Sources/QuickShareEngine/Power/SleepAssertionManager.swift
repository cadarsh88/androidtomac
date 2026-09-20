import Foundation
import IOKit.pwr_mgt

public final class SleepAssertionManager: @unchecked Sendable {
    public static let shared = SleepAssertionManager()
    private var assertionID: IOPMAssertionID = 0
    private var activeCount: Int = 0
    private let lock = NSLock()

    private init() {}

    public func beginActivity(reason: String = "Quick Share Active Transfer") {
        lock.lock()
        defer { lock.unlock() }

        activeCount += 1
        if activeCount == 1 {
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            if success == kIOReturnSuccess {
                #if DEBUG
                print("[SleepAssertion] Successfully acquired power assertion: \(assertionID)")
                #endif
            } else {
                print("[SleepAssertion] Failed to acquire power assertion: \(success)")
            }
        }
    }

    public func endActivity() {
        lock.lock()
        defer { lock.unlock() }

        guard activeCount > 0 else { return }
        activeCount -= 1

        if activeCount == 0 && assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            #if DEBUG
            print("[SleepAssertion] Released power assertion: \(assertionID)")
            #endif
            assertionID = 0
        }
    }
}
