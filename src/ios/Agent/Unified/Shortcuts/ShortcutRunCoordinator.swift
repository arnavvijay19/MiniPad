//
//  ShortcutRunCoordinator.swift
//  MinisApp
//
//  Suspends a tool call across an app switch.
//
//  Running a shortcut is the only agent operation whose result arrives through
//  `openURL` rather than through a return value: iOS foregrounds the Shortcuts
//  app, runs the shortcut, and comes back to us with a `minis://shortcut-callback`
//  URL. The tool call has to wait in between.
//
//  Three things make that harder than a plain continuation:
//
//    * The app can be suspended and resumed while the user is in Shortcuts, so
//      the wait has to survive a backgrounding.
//    * The callback may never arrive — the user can abandon the Shortcuts app,
//      or sit on a permission prompt. A tool call that waits forever hangs the
//      whole agent loop, so every run has a deadline.
//    * Two runs of the same shortcut can be outstanding, so results are matched
//      by generated token, never by name.
//
//  The correlation logic itself is `PendingShortcutRuns`, which is pure and
//  unit-tested. This actor is the async plumbing around it.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

actor ShortcutRunCoordinator {

    static let shared = ShortcutRunCoordinator()

    private var pending = PendingShortcutRuns()
    private var waiters: [String: CheckedContinuation<ShortcutsBridge.Outcome, Never>] = [:]

    private init() {}

    // MARK: - Running

    enum RunError: LocalizedError {
        case shortcutsUnavailable
        case notRegistered(String)
        case couldNotOpen

        var errorDescription: String? {
            switch self {
            case .shortcutsUnavailable:
                return "The Shortcuts app isn't available on this device."
            case .notRegistered(let name):
                return "'\(name)' isn't in the shortcut list. Add it in Settings → Shortcuts first — iOS gives no way to discover a user's shortcuts automatically."
            case .couldNotOpen:
                return "Couldn't hand off to the Shortcuts app."
            }
        }
    }

    /// Run a registered shortcut and wait for its result.
    func run(name: String, input: String?) async throws -> ShortcutsBridge.Outcome {
        let registered = await MainActor.run { ShortcutRegistryStore.shared.find(name) }
        guard let registered, registered.enabled else {
            throw RunError.notRegistered(name)
        }

        let token = ShortcutsBridge.makeToken()
        let url = try ShortcutsBridge.runURL(
            name: registered.name,
            input: input,
            token: token,
            acceptsInput: registered.inputKind != .none
        )

        guard await openShortcuts(url) else { throw RunError.couldNotOpen }

        pending.register(token: token, shortcutName: registered.name)
        // Arm the deadline before suspending, so an abandoned run can't wedge
        // the agent loop.
        scheduleTimeout(token: token)

        return await withCheckedContinuation { continuation in
            waiters[token] = continuation
        }
    }

    /// Deliver a callback from the deep-link router.
    nonisolated func deliver(_ callback: ShortcutsBridge.Callback) {
        Task { await self.resolve(callback) }
    }

    private func resolve(_ callback: ShortcutsBridge.Callback) {
        // Claim first: an unknown token (a stale callback from a previous
        // launch, or one the user triggered by hand) must not resolve someone
        // else's run.
        guard pending.claim(token: callback.token) != nil else { return }
        waiters.removeValue(forKey: callback.token)?.resume(returning: callback.outcome)
    }

    private func scheduleTimeout(token: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PendingShortcutRuns.timeout * 1_000_000_000))
            await self?.expire(token: token)
        }
    }

    private func expire(token: String) {
        guard pending.claim(token: token) != nil else { return }   // already resolved
        waiters.removeValue(forKey: token)?.resume(returning: .failure(
            message: "no response from the Shortcuts app within "
                   + "\(Int(PendingShortcutRuns.timeout))s — the run may have been abandoned"
        ))
    }

    /// Sweep runs whose deadline passed while the app was suspended.
    ///
    /// The per-run timeout Task doesn't fire reliably across a suspension, so
    /// foregrounding also sweeps. Without this a run abandoned while the app was
    /// backgrounded stays pending until the process dies.
    func sweepExpired() {
        for stale in pending.expire() {
            waiters.removeValue(forKey: stale.token)?.resume(returning: .failure(
                message: "no response from the Shortcuts app for '\(stale.shortcutName)'"
            ))
        }
    }

    // MARK: - UIKit

    @MainActor
    private func openShortcuts(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        guard UIApplication.shared.canOpenURL(ShortcutsBridge.probeURL) else { return false }
        return await UIApplication.shared.open(url)
        #else
        return false
        #endif
    }

    /// Whether the Shortcuts app can be reached at all.
    ///
    /// Requires `shortcuts` in `LSApplicationQueriesSchemes` (Info.plist);
    /// without that entitlement `canOpenURL` always answers false and the agent
    /// would report Shortcuts as missing on every device.
    @MainActor
    static var isShortcutsAvailable: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.canOpenURL(ShortcutsBridge.probeURL)
        #else
        return false
        #endif
    }
}
