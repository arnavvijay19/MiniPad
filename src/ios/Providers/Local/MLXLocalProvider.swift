//
//  MLXLocalProvider.swift
//  MinisApp
//
//  In-process local inference, as an ordinary Minis AgentProvider.
//
//  WHY IT IS COMPILE-GATED
//
//  The runtime half of the file is inside `#if MINIS_LOCAL_INFERENCE`. Without the
//  `mlx-swift-lm` package added to the project, this compiles to a stub that
//  reports local inference as unavailable, and the rest of the app is
//  unaffected — no build break, no dead references, nothing to undo. Adding
//  the package (see docs/design/unified-agent/ARCHITECTURE.md) switches the
//  real implementation on with no other change.
//
//  That gating is deliberate and not merely cautious. MLX pulls in Metal
//  kernels and a large dependency tree, it raises the deployment floor, and it
//  is only useful on Apple silicon. A fork that hard-wires it makes every
//  future upstream merge harder for a capability not every user wants.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//
//  It does not implement inference. Writing a transformer runtime by hand would
//  be slower, more fragile and less correct than Apple's, which is maintained
//  against the models we care about. This file is an adapter: Minis' agent
//  vocabulary in, MLX's in-process generation out.
//
//  Reference: ml-explore/mlx-swift-lm (MIT), products MLXLLM / MLXLMCommon.
//

import Foundation

// MARK: - Availability (always compiled)

/// Whether this build can run models on-device, and why not when it can't.
///
/// Compiled unconditionally so settings, the model picker and the provider
/// factory can ask without themselves being gated.
enum LocalInferenceAvailability {

    /// True when the MLX runtime is linked into this build.
    static var isCompiledIn: Bool {
        // Must match the gate on MLXLocalProvider exactly, or settings would
        // advertise on-device inference that isn't actually compiled in.
        //
        // MINIS_LOCAL_INFERENCE, not canImport(MLXLLM): Xcode makes every
        // resolved package product visible to every target in the project, so
        // canImport is true even in a target that links no MLX product and
        // therefore cannot load the macro plugin behind
        // #huggingFaceLoadModelContainer. "Visible" and "built against" are
        // different questions and only the second is a safe gate.
        // scripts/add_mlx_package.py defines this on exactly the target that
        // links the packages.
        #if MINIS_LOCAL_INFERENCE
        return true
        #else
        return false
        #endif
    }

    /// True when the hardware can run it. MLX needs Apple silicon and Metal;
    /// the simulator has neither in a usable form.
    static var isSupportedHardware: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static var isAvailable: Bool { isCompiledIn && isSupportedHardware }

    /// Sentence for the settings row when local inference can't be used.
    static var unavailableReason: String? {
        if !isCompiledIn {
            return "This build was compiled without the on-device inference runtime (MLXLLM + MLXHuggingFace). See BUILDING.md → On-device inference."
        }
        if !isSupportedHardware {
            return "On-device models need Apple silicon. The simulator can't run them; use a physical device."
        }
        return nil
    }
}

/// Errors the local provider surfaces, worded for both the user and the model.
enum LocalInferenceError: Error, LocalizedError {
    case runtimeUnavailable(String)
    case modelNotDownloaded(String)
    case incompatibleModel(String)
    case loadFailed(String)
    case outOfMemory(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let detail): return detail
        case .modelNotDownloaded(let repo): return "\(repo) hasn't been downloaded yet."
        case .incompatibleModel(let detail): return detail
        case .loadFailed(let detail): return "Couldn't load the model: \(detail)"
        case .outOfMemory(let detail):
            return "Ran out of memory while running the model. \(detail)"
        case .cancelled: return "Cancelled."
        }
    }
}

// MARK: - Generation settings

/// User-facing generation parameters, independent of MLX so settings and
/// persistence don't need the package either.
struct LocalGenerationSettings: Codable, Hashable, Sendable {
    var temperature: Float
    var topP: Float
    var maxTokens: Int
    /// KV-cache ceiling in tokens. Beyond this MLX switches to a rotating
    /// cache, which bounds memory at the cost of forgetting the oldest tokens.
    /// Bounding it matters far more on a device than on a server: an unbounded
    /// cache on a long agent run is the most likely way to get OOM-killed.
    var maxKVSize: Int?
    /// Quantize the KV cache to this many bits once generation passes
    /// `quantizedKVStart` tokens. Roughly halves cache memory at 8 bits.
    var kvBits: Int?
    var quantizedKVStart: Int
    /// Penalty applied to tokens already seen in the last
    /// `repetitionContextSize` tokens.
    ///
    /// `GenerateParameters.repetitionPenalty` is `Float?` and defaults to nil,
    /// which is *no penalty at all*. A 4B model sampled at 0.3 has little
    /// headroom before it falls into a degenerate loop, and leaving this unset
    /// produced exactly that: the same paragraph repeated until maxTokens ran
    /// out. Frontier models hide this failure mode; a small local one does not.
    var repetitionPenalty: Float?
    /// How far back the penalty looks. 20 is MLX's own default.
    var repetitionContextSize: Int

    static let `default` = LocalGenerationSettings(
        temperature: 0.7, topP: 0.95, maxTokens: 2048,
        maxKVSize: 8192, kvBits: 8, quantizedKVStart: 2048,
        repetitionPenalty: 1.1, repetitionContextSize: 20
    )

    /// Lower temperature for agent work.
    ///
    /// Tool-calling wants the model to reproduce a schema exactly. Sampling
    /// diversity that reads as "creative" in prose reads as a malformed JSON
    /// argument in a tool call, and a 4B model has much less headroom for that
    /// than a frontier model does.
    static let agentic = LocalGenerationSettings(
        temperature: 0.3, topP: 0.9, maxTokens: 2048,
        maxKVSize: 8192, kvBits: 8, quantizedKVStart: 2048,
        repetitionPenalty: 1.1, repetitionContextSize: 20
    )
}

// MARK: - Tool schema conversion (always compiled, testable)

/// Converts Minis' canonical tool definitions into the OpenAI-style function
/// schema dictionaries MLX renders into the chat template.
///
/// Compiled unconditionally so the schema shape — which is what the local model
/// actually sees, and therefore what the context budget is spent on — can be
/// tested without the package.
enum LocalToolSchemaBuilder {

    /// One tool, as a JSON-schema function object.
    ///
    /// The element type is `[String: any Sendable]`, not `[String: Any]`,
    /// because that is exactly `MLXLMCommon.ToolSpec` — and `[String: Any]`
    /// does **not** convert to it. Building the dictionaries as `Any` and
    /// casting at the call site fails to compile, which is how this was caught:
    /// see scripts/typecheck_mlx_adapter.sh, which typechecks this mapping
    /// against the real upstream type definitions.
    static func schema(for tool: AgentToolDefinition) -> [String: any Sendable] {
        var properties: [String: any Sendable] = [:]
        for (name, param) in tool.parameters {
            var entry: [String: any Sendable] = [
                "type": param.type.rawValue,
                "description": param.description,
            ]
            if let values = param.enumValues { entry["enum"] = values }
            properties[name] = entry
        }
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    static func schemas(for tools: [AgentToolDefinition]) -> [[String: any Sendable]] {
        tools.map(schema(for:))
    }

    /// Stable hash of a tool set, for the session-reuse decision. Tool schemas
    /// are rendered into the prompt prefix, so a change invalidates the cache.
    static func hash(_ tools: [AgentToolDefinition]) -> Int {
        // Sorted by name so a reordering — which the chat template renders
        // identically in practice for our templates — doesn't force a needless
        // rebuild, while any real change to a name, description, parameter or
        // required list does.
        let canonical = tools
            .sorted { $0.name < $1.name }
            .map { tool -> String in
                let params = tool.parameters
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value.type.rawValue):\($0.value.description)" }
                    .joined(separator: "|")
                return "\(tool.name)|\(tool.description)|\(params)|\(tool.required.sorted().joined(separator: ","))"
            }
            .joined(separator: "\n")
        return TranscriptFingerprint.stableHash(canonical)
    }
}

// MARK: - Transcript rendering (always compiled, testable)

/// Flattens Minis' `AgentMessage` parts into the plain text + tool metadata
/// that a local chat template consumes.
///
/// Local models get no images (the seed catalog is text-only), so an image part
/// becomes a short, honest placeholder rather than being silently dropped — a
/// dropped attachment makes the model confidently answer about a picture it
/// never saw.
enum LocalTranscriptRenderer {

    struct RenderedMessage: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case user
            case assistant(toolCalls: [(id: String, name: String, argumentsJSON: String)])
            case toolResult(id: String, name: String)

            static func == (lhs: Kind, rhs: Kind) -> Bool {
                switch (lhs, rhs) {
                case (.user, .user): return true
                case (.assistant(let a), .assistant(let b)):
                    return a.map(\.id) == b.map(\.id) && a.map(\.argumentsJSON) == b.map(\.argumentsJSON)
                case (.toolResult(let ai, let an), .toolResult(let bi, let bn)):
                    return ai == bi && an == bn
                default: return false
                }
            }
        }
        let kind: Kind
        let text: String
    }

    /// Split an agent transcript into template-ready messages.
    ///
    /// A tool result becomes its own message rather than being folded into the
    /// user turn, because every chat template we target renders the `tool` role
    /// distinctly, and collapsing it teaches the model that tool output is
    /// something the user said.
    static func render(_ messages: [AgentMessage]) -> [RenderedMessage] {
        var out: [RenderedMessage] = []
        for message in messages {
            var text = ""
            var toolCalls: [(id: String, name: String, argumentsJSON: String)] = []
            var pendingResults: [RenderedMessage] = []

            for part in message.parts {
                switch part {
                case .text(let value):
                    if !value.isEmpty {
                        if !text.isEmpty { text += "\n" }
                        text += value
                    }
                case .toolUse(let id, let name, let input):
                    let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append((id: sanitizeToolId(id), name: name, argumentsJSON: json))
                case .toolResult(let id, let name, let content, let isError, _, _, _, _):
                    pendingResults.append(RenderedMessage(
                        kind: .toolResult(id: sanitizeToolId(id), name: name),
                        text: isError ? "Error: \(content)" : content
                    ))
                case .imageData:
                    if !text.isEmpty { text += "\n" }
                    text += "[an image was attached; this on-device model cannot see images]"
                }
            }

            switch message.role {
            case .user:
                // Tool results ride on user messages in Minis' representation;
                // they must be emitted as `tool` messages, and before any
                // genuine user text in the same message.
                out.append(contentsOf: pendingResults)
                if !text.isEmpty {
                    out.append(RenderedMessage(kind: .user, text: text))
                }
            case .assistant:
                // An assistant turn that is only tool calls still has to exist
                // in the transcript, or the tool results that follow have
                // nothing to answer.
                if !text.isEmpty || !toolCalls.isEmpty {
                    out.append(RenderedMessage(kind: .assistant(toolCalls: toolCalls), text: text))
                }
                out.append(contentsOf: pendingResults)
            }
        }
        return out
    }

    /// Fingerprints for the session-reuse decision.
    static func fingerprints(_ rendered: [RenderedMessage]) -> [TranscriptFingerprint] {
        rendered.map { message in
            switch message.kind {
            case .user:
                return TranscriptFingerprint(role: "user", content: message.text)
            case .assistant(let calls):
                let callText = calls.map { "\($0.name)(\($0.argumentsJSON))" }.joined(separator: ";")
                return TranscriptFingerprint(role: "assistant", content: message.text + "\u{1}" + callText)
            case .toolResult(let id, let name):
                return TranscriptFingerprint(role: "tool", content: "\(id)\u{1}\(name)\u{1}\(message.text)")
            }
        }
    }
}

// MARK: - The provider

#if MINIS_LOCAL_INFERENCE

import MLX
import MLXLLM
import MLXLMCommon
// The Hugging Face download path is a macro, not a function: MLXLMCommon's
// `loadModelContainer` requires an explicit `Downloader` and `TokenizerLoader`,
// and `#huggingFaceLoadModelContainer` is what supplies the default pair.
// Expanding it references `HuggingFace.HubClient` and `Tokenizers`, so those
// modules must be linked too — see BUILDING.md.
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// MLX's chat session, disambiguated from this app's own `ChatSession`.
///
/// `ChatStore.swift` declares `struct ChatSession: Identifiable, Codable` — a
/// stored conversation. A type in the current module always wins over one from
/// an imported module, so an unqualified `ChatSession` here silently resolves
/// to the app's model. The failure is not a name clash the compiler points at;
/// it is `argument type 'ModelContainer' does not conform to expected type
/// 'Decoder'`, because the call landed on `Codable`'s `init(from:)`.
/// Internal, not private: `LocalModelRuntime`'s methods are internal and
/// return this type, and Swift refuses to let an internal signature mention a
/// private one.
typealias LLMChatSession = MLXLMCommon.ChatSession

/// Holds one loaded model and serialises access to it.
///
/// An actor because a single `ModelContainer` cannot service two generations
/// concurrently — and unlike a remote provider, where concurrent requests are
/// simply more HTTP, here they would contend for the same GPU buffers and the
/// same KV cache. The agent loop's concurrent tool dispatch means this is a
/// real path, not a hypothetical one.
actor LocalModelRuntime {

    static let shared = LocalModelRuntime()

    private var container: ModelContainer?
    private var loadedRepoID: String?
    private var sessions: [String: LLMChatSession] = [:]
    private var sessionStates: [String: LocalSessionState] = [:]

    private init() {}

    var currentRepoID: String? { loadedRepoID }
    var isLoaded: Bool { container != nil }

    /// Load a model, reusing it when it's already resident.
    ///
    /// Switching models unloads the previous one first. Holding two 4-bit
    /// models at once is ~9GB on the seed catalog's largest pair, which no iPad
    /// will tolerate.
    func load(
        repoID: String,
        cacheLimitBytes: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelContainer {
        if let container, loadedRepoID == repoID { return container }
        if loadedRepoID != nil { unload() }

        // A multi-gigabyte download with no visible progress reads as a hang,
        // and the user cannot tell it from one. Report into the store so the
        // settings row shows a bar and the chat indicator says what is going on.
        //
        // Checked once, here, rather than in the view: `isDownloaded` scans the
        // cache directory, and the view re-renders on every progress tick.
        let alreadyOnDisk = await MainActor.run { LocalModelStore.shared.isDownloaded(repoID) }
        await MainActor.run {
            LocalModelStore.shared.setState(
                alreadyOnDisk ? .loading : .downloading(fraction: 0), repoID: repoID)
        }

        // Cap MLX's buffer cache. Without this the allocator keeps freed
        // buffers around, which on a memory-limited device reads to the OS as
        // sustained high usage and gets the app jetsammed during an unrelated
        // spike. `GPU.set(cacheLimit:)` is deprecated in mlx-swift 0.31 in
        // favour of this property.
        MLX.Memory.cacheLimit = cacheLimitBytes

        do {
            let configuration = ModelConfiguration(id: repoID)
            // The macro supplies the default Hub downloader and tokenizer
            // loader. There is no `loadContainer(configuration:)` convenience —
            // every non-macro entry point requires both explicitly.
            let loaded = try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { p in
                    progress?(p.fractionCompleted)
                    // The Hub still reports progress while verifying files it
                    // already has. Letting that through would relabel a cached
                    // load as a download partway in.
                    guard !alreadyOnDisk else { return }
                    Task { @MainActor in
                        LocalModelStore.shared.setState(
                            .downloading(fraction: p.fractionCompleted), repoID: repoID)
                    }
                }
            )
            container = loaded
            loadedRepoID = repoID
            await MainActor.run {
                LocalModelStore.shared.setState(.loaded, repoID: repoID)
                LocalModelLifecycle.shared.noteModelLoaded()
            }
            return loaded
        } catch {
            unload()
            await MainActor.run {
                LocalModelStore.shared.setState(
                    .failed(error.localizedDescription), repoID: repoID)
            }
            throw LocalInferenceError.loadFailed(error.localizedDescription)
        }
    }

    /// Drop the model and every derived session.
    ///
    /// Called on model switch, on a memory-pressure warning, and when the user
    /// unloads manually. Sessions must go with it: an LLMChatSession holds a KV
    /// cache tied to the container's weights, and keeping one across an unload
    /// is a use-after-free waiting to happen.
    func unload() {
        sessions.removeAll()
        sessionStates.removeAll()
        container = nil
        loadedRepoID = nil
        // `GPU.clearCache()` is deprecated; renamed to Memory.clearCache.
        MLX.Memory.clearCache()
    }

    /// Drop MLX's buffer cache while keeping the model resident.
    ///
    /// The cheap first response to a memory warning: the allocator holds freed
    /// buffers that the OS still counts as this process's footprint, and
    /// releasing them is often enough to avoid a jetsam without paying a
    /// 20-second reload.
    func clearBufferCache() {
        MLX.Memory.clearCache()
    }

    /// Reset one conversation's session without unloading the model. Used when
    /// the transcript diverges (compaction, edit, retry).
    func resetSession(conversationID: String) {
        sessions.removeValue(forKey: conversationID)
        sessionStates.removeValue(forKey: conversationID)
    }

    func sessionState(conversationID: String) -> LocalSessionState? {
        sessionStates[conversationID]
    }

    func session(conversationID: String) -> LLMChatSession? {
        sessions[conversationID]
    }

    func store(session: LLMChatSession, state: LocalSessionState, conversationID: String) {
        sessions[conversationID] = session
        sessionStates[conversationID] = state
    }
}

/// Minis `AgentProvider` backed by MLX.
final class MLXLocalProvider: AgentProvider, @unchecked Sendable {

    let name: String
    let model: LLMModel
    var defaultMaxTokens: Int { settings.maxTokens }

    private let repoID: String
    private let settings: LocalGenerationSettings
    private let conversationID: String
    private let cacheLimitBytes: Int

    init(
        repoID: String,
        model: LLMModel,
        conversationID: String,
        settings: LocalGenerationSettings = .agentic,
        cacheLimitBytes: Int = 512 * 1024 * 1024
    ) {
        self.repoID = repoID
        self.model = model
        self.name = "On-device"
        self.conversationID = conversationID
        self.settings = settings
        self.cacheLimitBytes = cacheLimitBytes
    }

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard LocalInferenceAvailability.isAvailable else {
            throw LocalInferenceError.runtimeUnavailable(
                LocalInferenceAvailability.unavailableReason ?? "On-device inference is unavailable."
            )
        }

        let rendered = LocalTranscriptRenderer.render(messages)
        let fingerprints = LocalTranscriptRenderer.fingerprints(rendered)
        let systemHash = TranscriptFingerprint.stableHash(systemPrompt ?? "")
        let toolsHash = LocalToolSchemaBuilder.hash(tools)
        // `schemas(for:)` already returns [[String: any Sendable]], which IS
        // [ToolSpec] — no cast, because the cast is what doesn't compile.
        let toolSpecs: [ToolSpec] = LocalToolSchemaBuilder.schemas(for: tools)

        let runtime = LocalModelRuntime.shared
        let container = try await runtime.load(repoID: repoID, cacheLimitBytes: cacheLimitBytes)

        let decision = LocalTranscriptDelta.decide(
            cached: await runtime.sessionState(conversationID: conversationID),
            systemPromptHash: systemHash,
            toolsHash: toolsHash,
            incoming: fingerprints
        )

        var parameters = GenerateParameters()
        parameters.temperature = settings.temperature
        parameters.topP = settings.topP
        parameters.maxTokens = min(maxTokens, settings.maxTokens)
        parameters.maxKVSize = settings.maxKVSize
        parameters.kvBits = settings.kvBits
        parameters.quantizedKVStart = settings.quantizedKVStart
        parameters.repetitionPenalty = settings.repetitionPenalty
        parameters.repetitionContextSize = settings.repetitionContextSize

        // Pick the session and the messages to feed it.
        let session: LLMChatSession
        let toFeed: [Chat.Message]
        switch decision {
        case .appendSuffix(let fromIndex):
            guard let existing = await runtime.session(conversationID: conversationID) else {
                // State said reuse but the session is gone — rebuild rather
                // than trusting stale bookkeeping.
                session = LLMChatSession(container, instructions: systemPrompt,
                                      generateParameters: parameters, tools: toolSpecs)
                toFeed = Self.chatMessages(Array(rendered))
                break
            }
            session = existing
            toFeed = Self.chatMessages(Array(rendered[fromIndex...]))
        case .rebuild:
            session = LLMChatSession(container, instructions: systemPrompt,
                                  generateParameters: parameters, tools: toolSpecs)
            toFeed = Self.chatMessages(rendered)
        }

        let conversationID = self.conversationID
        return AsyncThrowingStream { continuation in
            let task = Task {
                var assistantText = ""
                var sawToolCall = false
                // Qwen 3.5 and friends embed reasoning as a <think>…</think>
                // prefix of the generated text. Streaming that straight through
                // put the model's scratchpad in the reply body. The OpenAI path
                // already solved this; the parser is a pure string state machine
                // with nothing OpenAI-specific in it, so it is reused verbatim
                // rather than reimplemented. Non-reasoning output passes through
                // untouched, so this is safe for every model in the catalog.
                var think = OpenAIAgentProvider.ThinkPrefixStreamParser()

                func emitParsed(_ out: (thinking: String, visible: String)) {
                    // Gated like the OpenAI path: reasoning is only streamed
                    // when the user actually asked for thinking.
                    if !out.thinking.isEmpty, thinkingLevel.isEnabled {
                        continuation.yield(.thinkingDelta(out.thinking))
                    }
                    if !out.visible.isEmpty {
                        assistantText += out.visible
                        continuation.yield(.textDelta(out.visible))
                    }
                }

                do {
                    continuation.yield(.contentBlockStart(.text))
                    for try await generation in session.streamDetails(to: toFeed) {
                        try Task.checkCancellation()
                        switch generation {
                        case .chunk(let text):
                            emitParsed(think.consume(text))
                        case .toolCall(let call):
                            sawToolCall = true
                            let id = "local-\(UUID().uuidString.prefix(8))"
                            let args = call.function.arguments.mapValues { $0.anyValue }
                            continuation.yield(.contentBlockStart(
                                .toolUse(id: id, name: call.function.name)))
                            continuation.yield(.toolCallComplete(
                                id: id, name: call.function.name, args: args, metadata: nil))
                        case .rejectedToolCall(let rejection):
                            // MLX's parser refused it. Try to recover the call
                            // rather than burning a whole turn — a 4B model
                            // reproduces the same mistake on retry often enough
                            // that rejection alone is not a strategy.
                            //
                            // Salvage reads `rawTextPreview`, which is the
                            // model's own output, not `String(describing:)` of
                            // the rejection — that would be Swift's rendering
                            // of a struct, and the repair rules would be
                            // parsing punctuation this code emitted.
                            //
                            // A truncated preview is refused outright.
                            // `isPreviewTruncated` means bytes are missing from
                            // the *middle*, and completing JSON across a hole
                            // does not recover arguments, it invents them. The
                            // salvage rules already refuse to close a
                            // truncation at the end for the same reason.
                            guard !rejection.isPreviewTruncated else {
                                assistantText += "\n[a tool call was rejected: "
                                    + "\(rejection.reason.rawValue), and its output was "
                                    + "too long to recover safely]"
                                break
                            }
                            for salvaged in LocalToolCallSalvage.salvage(
                                from: rejection.rawTextPreview
                            ) {
                                // The parser may have recovered the name safely
                                // even when it could not build the whole call.
                                // Prefer its answer to ours, and never proceed
                                // when the two disagree — a wrong tool name is
                                // the one salvage error with real consequences.
                                if let known = rejection.toolName, known != salvaged.name {
                                    continue
                                }
                                sawToolCall = true
                                let id = "local-\(UUID().uuidString.prefix(8))"
                                continuation.yield(.contentBlockStart(
                                    .toolUse(id: id, name: salvaged.name)))
                                continuation.yield(.toolCallComplete(
                                    id: id, name: salvaged.name,
                                    args: salvaged.arguments.mapValues { $0.anyValue },
                                    metadata: nil))
                            }
                        case .info(let info):
                            // nil, not 0, for the cache fields: there is no
                            // prompt cache on device to report. KV-cache reuse
                            // is a different thing entirely — it saves
                            // *computation*, not billed input tokens — and
                            // reporting 0 would read as "the cache was checked
                            // and missed" everywhere this is displayed.
                            continuation.yield(.usage(LLMUsage(
                                inputTokens: info.promptTokenCount,
                                outputTokens: info.generationTokenCount,
                                cacheCreationInputTokens: nil,
                                cacheReadInputTokens: nil
                            )))
                        }
                    }

                    // Flush whatever the parser is still holding: the trailing
                    // bytes it withholds in case they turn out to be a partial
                    // "</think>", and the body text of a turn that ended
                    // without ever closing its tag. Without this, the tail of
                    // every reply is silently dropped.
                    emitParsed(think.finishTurn())

                    // Record what this session now holds, including the
                    // assistant's own reply — omitting it would make the next
                    // turn look diverged and force a rebuild every time.
                    let replyFingerprint = TranscriptFingerprint(
                        role: "assistant",
                        content: assistantText + "\u{1}" + (sawToolCall ? "tool" : "")
                    )
                    await LocalModelRuntime.shared.store(
                        session: session,
                        state: LocalTranscriptDelta.advanced(
                            nil, systemPromptHash: systemHash, toolsHash: toolsHash,
                            incoming: fingerprints, assistantReply: replyFingerprint
                        ),
                        conversationID: conversationID
                    )
                    continuation.yield(.done(stopReason: sawToolCall ? .toolUse : .endTurn))
                    continuation.finish()
                } catch is CancellationError {
                    // The session's cache is now out of step with what the
                    // transcript says was generated, so drop it.
                    await LocalModelRuntime.shared.resetSession(conversationID: conversationID)
                    continuation.finish(throwing: LocalInferenceError.cancelled)
                } catch {
                    await LocalModelRuntime.shared.resetSession(conversationID: conversationID)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map rendered messages onto MLX's chat vocabulary.
    private static func chatMessages(_ rendered: [LocalTranscriptRenderer.RenderedMessage])
        -> [Chat.Message] {
        rendered.map { message in
            switch message.kind {
            case .user:
                return Chat.Message(role: .user, content: message.text)
            case .assistant(let calls):
                let toolCalls = calls.map { call -> ToolCall in
                    let args: [String: JSONValue]
                    if let data = call.argumentsJSON.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                        args = decoded
                    } else {
                        args = [:]
                    }
                    return ToolCall(function: .init(name: call.name, arguments: args), id: call.id)
                }
                return Chat.Message(
                    role: .assistant, content: message.text,
                    tool: toolCalls.isEmpty ? nil : .calls(toolCalls)
                )
            case .toolResult(let id, let name):
                return Chat.Message(role: .tool, content: message.text,
                                    tool: .result(id: id, name: name))
            }
        }
    }
}

#endif
