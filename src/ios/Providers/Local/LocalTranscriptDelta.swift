//
//  LocalTranscriptDelta.swift
//  MinisApp
//
//  Deciding whether a local model can keep its KV cache between turns.
//
//  WHY THIS IS THE MOST IMPORTANT FILE IN THE LOCAL-INFERENCE PATH
//
//  The Minis agent loop is stateless per request: it hands the provider the
//  whole conversation every turn. That is exactly right for a remote provider —
//  the server does prefix caching, and the app gets retries, edits, compaction
//  and model switching for free.
//
//  On-device it is ruinous. An agent turn is: send transcript → model calls a
//  tool → append the result → send transcript again. If the model re-processes
//  the entire transcript each time, prompt processing dominates everything. A
//  three-tool task on an 8K transcript re-processes ~24K tokens of prompt to
//  generate a few hundred, and the user watches a spinner between every step.
//
//  MLX's `ChatSession` keeps a KV cache across calls, so the fix is to feed it
//  only the messages it hasn't seen. The risk is feeding it a delta when the
//  earlier part of the transcript actually *changed* — after a compaction, an
//  edited message, or a retry — because then the cache represents a prompt the
//  user is no longer having, and the model answers the wrong conversation with
//  no visible error.
//
//  So the decision is conservative: reuse only when the previous transcript is
//  an exact prefix of the new one, by content, message for message. Anything
//  else rebuilds. A needless rebuild costs time; a wrong reuse costs
//  correctness, and only one of those is recoverable.
//
//  Pure Foundation, unit-tested.
//

import Foundation

/// A content fingerprint for one message in the transcript.
///
/// Comparing fingerprints rather than whole messages keeps the retained state
/// small (a long conversation with images would otherwise be duplicated) and
/// makes the prefix check cheap enough to run on every turn.
struct TranscriptFingerprint: Hashable, Sendable {
    let role: String
    /// Stable hash of the message's rendered content, including tool calls and
    /// tool results. Two messages with the same fingerprint produce the same
    /// tokens.
    let contentHash: Int

    init(role: String, content: String) {
        self.role = role
        self.contentHash = TranscriptFingerprint.stableHash(content)
    }

    /// Explicit hash rather than `String.hashValue`.
    ///
    /// Swift seeds `Hashable` per process launch, so `hashValue` differs
    /// between runs. That is fine for an in-memory cache — which is all this is
    /// — but pinning it here means the fingerprints are reproducible in tests
    /// and would stay valid if this state were ever persisted. FNV-1a, 64-bit.
    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}

/// What to do with the live session for this turn.
enum TranscriptDeltaDecision: Equatable, Sendable {
    /// Keep the session and feed it messages from `fromIndex` onward.
    case appendSuffix(fromIndex: Int)
    /// Discard the session and prefill the whole transcript.
    case rebuild(reason: RebuildReason)

    enum RebuildReason: String, Equatable, Sendable {
        /// Nothing cached yet.
        case noSession
        /// The system prompt changed — it is the first thing in the prompt, so
        /// nothing after it is reusable.
        case systemPromptChanged
        /// The tool set changed. Tool schemas are rendered into the prompt by
        /// the chat template, so a different tool set is a different prefix.
        case toolsChanged
        /// The new transcript is shorter than the cached one: a compaction, a
        /// deleted message, or a retry that rewound the conversation.
        case transcriptShortened
        /// An earlier message's content differs — an edit or a regeneration.
        case historyDiverged
        /// The transcript is unchanged; there is nothing to append. Treated as
        /// a rebuild because feeding zero messages would leave the model with
        /// no turn to answer.
        case noNewMessages
    }

    var reusesCache: Bool {
        if case .appendSuffix = self { return true }
        return false
    }
}

/// The state a live local session carries between turns.
struct LocalSessionState: Sendable {
    var systemPromptHash: Int
    var toolsHash: Int
    var fingerprints: [TranscriptFingerprint]

    init(systemPromptHash: Int, toolsHash: Int, fingerprints: [TranscriptFingerprint]) {
        self.systemPromptHash = systemPromptHash
        self.toolsHash = toolsHash
        self.fingerprints = fingerprints
    }
}

enum LocalTranscriptDelta {

    /// Decide how this turn relates to what the session already holds.
    ///
    /// - Parameters:
    ///   - cached: state from the previous turn, or nil if there is no session.
    ///   - systemPromptHash: hash of this turn's system prompt.
    ///   - toolsHash: hash of this turn's tool schemas.
    ///   - incoming: fingerprints of this turn's full transcript.
    static func decide(
        cached: LocalSessionState?,
        systemPromptHash: Int,
        toolsHash: Int,
        incoming: [TranscriptFingerprint]
    ) -> TranscriptDeltaDecision {
        guard let cached else { return .rebuild(reason: .noSession) }

        // The system prompt and the tool schemas are rendered at the very front
        // of the prompt by the chat template. If either changed, every token
        // after it shifts, and no suffix of the cache is valid.
        if cached.systemPromptHash != systemPromptHash {
            return .rebuild(reason: .systemPromptChanged)
        }
        if cached.toolsHash != toolsHash {
            return .rebuild(reason: .toolsChanged)
        }

        // Shorter means the conversation was rewound — compaction, a deleted
        // message, a retry. The cache holds tokens that no longer exist.
        if incoming.count < cached.fingerprints.count {
            return .rebuild(reason: .transcriptShortened)
        }

        // Every cached message must still be present, unchanged, in the same
        // position. This is the check that prevents the model from answering a
        // conversation the user has since edited.
        for (index, fingerprint) in cached.fingerprints.enumerated()
        where incoming[index] != fingerprint {
            _ = index
            return .rebuild(reason: .historyDiverged)
        }

        if incoming.count == cached.fingerprints.count {
            return .rebuild(reason: .noNewMessages)
        }
        return .appendSuffix(fromIndex: cached.fingerprints.count)
    }

    /// Fold a completed turn back into the session state.
    static func advanced(
        _ state: LocalSessionState?,
        systemPromptHash: Int,
        toolsHash: Int,
        incoming: [TranscriptFingerprint],
        assistantReply: TranscriptFingerprint?
    ) -> LocalSessionState {
        var fingerprints = incoming
        // The assistant's own reply is in the session's cache too — leaving it
        // out would make the NEXT turn look like history diverged at that
        // position and force a rebuild every single turn, which is the exact
        // failure this file exists to prevent.
        if let assistantReply { fingerprints.append(assistantReply) }
        _ = state
        return LocalSessionState(
            systemPromptHash: systemPromptHash,
            toolsHash: toolsHash,
            fingerprints: fingerprints
        )
    }
}
