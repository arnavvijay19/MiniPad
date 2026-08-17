//
//  ToolDisclosureState.swift
//  MinisApp
//
//  Which specialist tools have been disclosed, per session.
//
//  `ToolSurfacePolicy` is pure — it takes the already-disclosed set and returns
//  the new one. Something has to hold that set between turns, and it must be
//  scoped per session: two chats have different subject matter, and a browser
//  disclosed in one should not cost the other its context.
//
//  Kept in a side table rather than as a stored property on AIChatViewModel so
//  the upstream class is untouched. That matters more than it looks: the view
//  model is a 5,800-line file that upstream changes constantly, and every
//  stored property added here is a rebase conflict later.
//
//  In memory only. Disclosure is cheap to re-derive from the conversation on
//  the next turn, and persisting it would keep an expensive schema loaded
//  across a relaunch for a topic the user has moved on from.
//

import Foundation

@MainActor
final class ToolDisclosureState {

    static let shared = ToolDisclosureState()

    private var disclosed: [String: Set<String>] = [:]

    private init() {}

    func disclosed(for sessionID: String?) -> Set<String> {
        guard let sessionID else { return [] }
        return disclosed[sessionID] ?? []
    }

    func record(_ names: Set<String>, for sessionID: String?) {
        guard let sessionID else { return }
        disclosed[sessionID] = names
    }

    /// Forget a session's disclosures — on delete, or on a compaction that
    /// removes the messages the triggers were derived from.
    func reset(sessionID: String) {
        disclosed.removeValue(forKey: sessionID)
    }

    /// Bound the table so a long-lived process doesn't accumulate an entry per
    /// session ever opened.
    func prune(keeping liveSessionIDs: Set<String>) {
        disclosed = disclosed.filter { liveSessionIDs.contains($0.key) }
    }
}
