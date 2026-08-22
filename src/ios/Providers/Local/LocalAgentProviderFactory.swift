//
//  LocalAgentProviderFactory.swift
//  MinisApp
//
//  The ungated entry point to on-device inference.
//
//  `MLXLocalProvider` lives behind `#if MINIS_LOCAL_INFERENCE`,
//  so nothing outside that gate can name the type. The agent loop still has to
//  be able to ask for a local provider without itself being gated — that is
//  what this file is for.
//
//  When the runtime isn't compiled in, it returns a provider that streams one
//  honest sentence rather than nil. Returning nil would send the caller down
//  the "no provider" path, which builds an empty-credential Anthropic client
//  and surfaces an authentication error — a confusing lie about what went
//  wrong. A user who selected an on-device model in a build without the runtime
//  should be told exactly that.
//

import Foundation

enum LocalAgentProviderFactory {

    /// Build an agent provider for a local model entry.
    ///
    /// - Parameters:
    ///   - repoID: Hugging Face repo id, e.g. `mlx-community/Qwen3.5-4B-4bit`.
    ///   - model: the entry's `LLMModel`, for display and context accounting.
    ///   - conversationID: scopes the KV-cache session, so two chats don't
    ///     share (and invalidate) each other's prompt cache.
    static func make(
        repoID: String,
        model: LLMModel,
        conversationID: String,
        settings: LocalGenerationSettings = .agentic
    ) -> AgentProvider {
        #if MINIS_LOCAL_INFERENCE
        if LocalInferenceAvailability.isSupportedHardware {
            return MLXLocalProvider(
                repoID: repoID, model: model,
                conversationID: conversationID, settings: settings
            )
        }
        #endif
        return UnavailableLocalProvider(
            model: model,
            reason: LocalInferenceAvailability.unavailableReason
                ?? "On-device inference is unavailable in this build."
        )
    }

    /// The tool-surface mode a model should use.
    ///
    /// Local models get the lean surface — the measured 68% cut in permanent
    /// tool-schema tokens (see ToolSurfacePolicy). Remote models keep the full
    /// surface, so their behaviour is byte-identical to upstream.
    static func toolSurfaceMode(forModelID id: String) -> ToolSurfaceMode {
        LocalModelEntry.repoID(fromAppModelID: id) != nil ? .lean : .full
    }
}

/// Streams a single explanatory error.
///
/// Conforms to `AgentProvider` so the agent loop, the UI and the error paths
/// all treat it like any other model instead of needing a special case.
struct UnavailableLocalProvider: AgentProvider {

    let name = "On-device"
    let model: LLMModel
    let reason: String
    var defaultMaxTokens: Int { 1 }

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let reason = self.reason
        return AsyncThrowingStream { continuation in
            // Thrown rather than yielded as text: a failure that renders as an
            // assistant message looks like the model answered, and the agent
            // loop would happily continue the conversation from it.
            continuation.finish(throwing: LocalInferenceError.runtimeUnavailable(reason))
        }
    }
}
