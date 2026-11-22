import Foundation
import os

#if os(macOS)
import IOKit.pwr_mgt
#elseif os(iOS)
import UIKit
#endif

/// Keeps the screen on while work is running. Calls nest: the screen may
/// sleep again once every `begin` has had its `end`.
@MainActor
protocol ScreenAwakeHolding: AnyObject {
    func begin()
    func end()
}

@MainActor
final class ScreenAwakeService: ScreenAwakeHolding {
    static let shared = ScreenAwakeService()

    private static let logger = Logger(subsystem: Log.subsystem, category: "ScreenAwake")

    private var activeCount = 0
    private var isActive: Bool { activeCount > 0 }

    #if os(macOS)
    private var assertionID: IOPMAssertionID = 0
    #endif

    private init() {}

    func begin() {
        activeCount += 1
        if activeCount == 1 { apply(true) }
    }

    func end() {
        guard activeCount > 0 else { return }
        activeCount -= 1
        if activeCount == 0 { apply(false) }
    }

    private func apply(_ active: Bool) {
        #if os(macOS)
        if active {
            preventSleep()
        } else {
            allowSleep()
        }
        #elseif os(iOS)
        // Delay idle timer changes on iOS to avoid interfering with
        // keyboard state and responder chain updates.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            // Re-check that we still want this state after the delay
            guard isActive == active else { return }
            UIApplication.shared.isIdleTimerDisabled = active
        }
        #endif
    }

    #if os(macOS)
    private func preventSleep() {
        let reason = "Madrigal is communicating with the AI model" as CFString
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if success != kIOReturnSuccess {
            Self.logger.error("Failed to create power assertion: \(success)")
        }
    }

    private func allowSleep() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
    #endif
}
