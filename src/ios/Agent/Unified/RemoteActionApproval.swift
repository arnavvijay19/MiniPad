//
//  RemoteActionApproval.swift
//  MinisApp
//
//  The confirmation gate for consequential remote operations.
//
//  Mirrors OffloadPermissionManager's shape (a `PermissionResult`, a per-scope
//  "always allow" memory) rather than inventing a second permission vocabulary,
//  so the two feel like one system to the user.
//
//  One deliberate difference: the remembered choice is scoped to the endpoint,
//  not global. "Always allow" on the laptop you use for scratch work should not
//  silently apply to a work machine added later.
//

import Foundation

@MainActor
final class RemoteActionApproval: ObservableObject {

    static let shared = RemoteActionApproval()

    /// A prompt waiting for the user. The UI observes this.
    @Published private(set) var pending: Request?

    struct Request: Identifiable {
        let id = UUID()
        let message: String
        let endpointId: String
        fileprivate let respond: (PermissionResult) -> Void
    }

    /// Endpoints the user chose to stop being asked about, this launch.
    ///
    /// In memory only, deliberately. A persisted blanket approval for arbitrary
    /// remote code execution is not something to grant across restarts from a
    /// one-tap prompt; the user can re-grant it in a second when it matters.
    private var alwaysAllowed: Set<String> = []

    /// Set when the user has turned confirmations off entirely in Settings.
    /// Separate from `alwaysAllowed` because it is an explicit, visible,
    /// persisted setting rather than something dismissed in a hurry.
    private static let confirmationsDisabledKey = "unifiedAgent.remote.skipConfirmations"

    var confirmationsDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.confirmationsDisabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.confirmationsDisabledKey) }
    }

    private init() {}

    /// Ask the user. Suspends until they answer.
    func request(message: String, endpointId: String) async -> PermissionResult {
        if confirmationsDisabled || alwaysAllowed.contains(endpointId) { return .allowed }

        // One prompt at a time. Concurrent tool dispatch means two destructive
        // calls can arrive together; stacking prompts would have the user
        // approving one while reading the other.
        while pending != nil {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if confirmationsDisabled || alwaysAllowed.contains(endpointId) { return .allowed }
        }

        return await withCheckedContinuation { continuation in
            pending = Request(message: message, endpointId: endpointId) { [weak self] result in
                self?.pending = nil
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Called by the UI

    func approve(_ request: Request, remember: Bool) {
        if remember { alwaysAllowed.insert(request.endpointId) }
        request.respond(.allowed)
    }

    func deny(_ request: Request) {
        // Worded for the model, not just the user: it has to understand that
        // retrying the identical command is pointless and that it should ask
        // rather than work around the refusal.
        request.respond(.denied(
            "The user declined this action on their PC. Do not retry it. "
            + "Explain what you were about to do and ask how they would like to proceed."
        ))
    }

    /// Cancel any outstanding prompt — used when the chat is torn down, so a
    /// suspended tool call can't outlive its conversation.
    func cancelPending() {
        pending?.respond(.denied("Cancelled."))
        pending = nil
    }
}
