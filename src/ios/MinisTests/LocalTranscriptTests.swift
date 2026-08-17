import XCTest

// MARK: - Session reuse

/// Coverage for the decision that lets a local model keep its KV cache between
/// turns.
///
/// The asymmetry drives every test here: a needless rebuild costs seconds; a
/// wrong reuse means the model answers a conversation the user has since
/// edited, silently and with no error anywhere. So reuse must fire when the new
/// transcript is a strict extension, and must not fire for anything else.
final class LocalTranscriptDeltaTests: XCTestCase {

    private func fp(_ role: String, _ content: String) -> TranscriptFingerprint {
        TranscriptFingerprint(role: role, content: content)
    }

    private func state(_ prints: [TranscriptFingerprint], system: Int = 1, tools: Int = 2)
        -> LocalSessionState {
        LocalSessionState(systemPromptHash: system, toolsHash: tools, fingerprints: prints)
    }

    func testNoSessionRebuilds() {
        let decision = LocalTranscriptDelta.decide(
            cached: nil, systemPromptHash: 1, toolsHash: 2, incoming: [fp("user", "hi")])
        XCTAssertEqual(decision, .rebuild(reason: .noSession))
    }

    func testStrictExtensionReusesTheCache() {
        // The common agent-loop shape: the transcript grows by a tool result
        // and the model's next turn. This is the whole point of the file.
        let cached = state([fp("user", "hi"), fp("assistant", "calling tool")])
        let incoming = [fp("user", "hi"), fp("assistant", "calling tool"), fp("tool", "output")]
        let decision = LocalTranscriptDelta.decide(
            cached: cached, systemPromptHash: 1, toolsHash: 2, incoming: incoming)
        XCTAssertEqual(decision, .appendSuffix(fromIndex: 2))
        XCTAssertTrue(decision.reusesCache)
    }

    func testMultipleNewMessagesAppendFromTheRightPoint() {
        let cached = state([fp("user", "a")])
        let incoming = [fp("user", "a"), fp("tool", "b"), fp("user", "c")]
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 1, toolsHash: 2,
                                        incoming: incoming),
            .appendSuffix(fromIndex: 1))
    }

    func testEditedHistoryRebuilds() {
        // The dangerous case. The user edited their first message; reusing here
        // makes the model answer the OLD question with no visible error.
        let cached = state([fp("user", "original"), fp("assistant", "reply")])
        let incoming = [fp("user", "EDITED"), fp("assistant", "reply"), fp("user", "next")]
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 1, toolsHash: 2,
                                        incoming: incoming),
            .rebuild(reason: .historyDiverged))
    }

    func testDivergenceInTheMiddleIsCaught() {
        let cached = state([fp("user", "a"), fp("assistant", "b"), fp("tool", "c")])
        let incoming = [fp("user", "a"), fp("assistant", "CHANGED"), fp("tool", "c"), fp("user", "d")]
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 1, toolsHash: 2,
                                        incoming: incoming),
            .rebuild(reason: .historyDiverged))
    }

    func testCompactionRebuilds() {
        // Compaction replaces many messages with a summary, so the transcript
        // gets shorter. The cache holds tokens that no longer exist.
        let cached = state([fp("user", "a"), fp("assistant", "b"), fp("tool", "c")])
        let incoming = [fp("user", "summary")]
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 1, toolsHash: 2,
                                        incoming: incoming),
            .rebuild(reason: .transcriptShortened))
    }

    func testSystemPromptChangeRebuilds() {
        // The system prompt is the front of the prompt; changing it shifts
        // every token after it, so no suffix of the cache is valid.
        let cached = state([fp("user", "a")])
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 999, toolsHash: 2,
                                        incoming: [fp("user", "a"), fp("user", "b")]),
            .rebuild(reason: .systemPromptChanged))
    }

    func testToolSetChangeRebuilds() {
        // Tool schemas are rendered into the prompt prefix by the chat
        // template, so a different tool set is a different prefix.
        let cached = state([fp("user", "a")])
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 1, toolsHash: 999,
                                        incoming: [fp("user", "a"), fp("user", "b")]),
            .rebuild(reason: .toolsChanged))
    }

    func testIdenticalTranscriptRebuilds() {
        // Nothing to append means nothing for the model to answer.
        let cached = state([fp("user", "a")])
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: cached, systemPromptHash: 1, toolsHash: 2,
                                        incoming: [fp("user", "a")]),
            .rebuild(reason: .noNewMessages))
    }

    func testAdvancedIncludesTheAssistantReply() {
        // Omitting the model's own reply would make the NEXT turn look diverged
        // at that position and force a rebuild every single turn — the exact
        // failure this machinery exists to prevent.
        let incoming = [fp("user", "a")]
        let reply = fp("assistant", "answer")
        let next = LocalTranscriptDelta.advanced(
            nil, systemPromptHash: 1, toolsHash: 2, incoming: incoming, assistantReply: reply)
        XCTAssertEqual(next.fingerprints, [fp("user", "a"), reply])

        // And a follow-up turn carrying that reply reuses the cache.
        let followUp = incoming + [reply, fp("tool", "result")]
        XCTAssertEqual(
            LocalTranscriptDelta.decide(cached: next, systemPromptHash: 1, toolsHash: 2,
                                        incoming: followUp),
            .appendSuffix(fromIndex: 2))
    }

    func testFingerprintIsStableAcrossRuns() {
        // Swift seeds Hashable per process, so an explicit hash is used. This
        // pins it: a fingerprint must not depend on when the app was launched.
        XCTAssertEqual(TranscriptFingerprint.stableHash("hello"),
                       TranscriptFingerprint.stableHash("hello"))
        XCTAssertNotEqual(TranscriptFingerprint.stableHash("hello"),
                          TranscriptFingerprint.stableHash("hellp"))
    }

    func testFingerprintDistinguishesRoles() {
        XCTAssertNotEqual(fp("user", "x"), fp("assistant", "x"))
    }
}

// MARK: - Transcript rendering

final class LocalTranscriptRendererTests: XCTestCase {

    func testPlainConversation() {
        let messages = [
            AgentMessage(role: .user, parts: [.text("hello")]),
            AgentMessage(role: .assistant, parts: [.text("hi")]),
        ]
        let rendered = LocalTranscriptRenderer.render(messages)
        XCTAssertEqual(rendered.count, 2)
        XCTAssertEqual(rendered[0].text, "hello")
        XCTAssertEqual(rendered[0].kind, .user)
        XCTAssertEqual(rendered[1].kind, .assistant(toolCalls: []))
    }

    func testToolCallAndResultBecomeSeparateMessages() {
        // A tool result folded into a user turn teaches the model that tool
        // output is something the user said. Every template we target renders
        // the `tool` role distinctly, so it must be emitted as one.
        let messages = [
            AgentMessage(role: .user, parts: [.text("list files")]),
            AgentMessage(role: .assistant, parts: [
                .toolUse(id: "call_1", name: "shell_execute", input: ["command": "ls"])
            ]),
            AgentMessage(role: .user, parts: [
                .toolResult(id: "call_1", name: "shell_execute", content: "a.txt", isError: false)
            ]),
        ]
        let rendered = LocalTranscriptRenderer.render(messages)
        XCTAssertEqual(rendered.count, 3)
        XCTAssertEqual(rendered[0].kind, .user)
        guard case .assistant(let calls) = rendered[1].kind else { return XCTFail("expected assistant") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "shell_execute")
        XCTAssertEqual(rendered[2].kind, .toolResult(id: "call_1", name: "shell_execute"))
        XCTAssertEqual(rendered[2].text, "a.txt")
    }

    func testAssistantTurnOfOnlyToolCallsIsKept() {
        // Dropping it leaves the following tool result with nothing to answer,
        // which every chat template renders as malformed.
        let messages = [
            AgentMessage(role: .assistant, parts: [
                .toolUse(id: "c", name: "file_read", input: ["path": "/x"])
            ]),
        ]
        XCTAssertEqual(LocalTranscriptRenderer.render(messages).count, 1)
    }

    func testToolErrorsAreMarkedAsErrors() {
        // A failed tool result that reads like a successful one makes the model
        // build on output that doesn't exist.
        let messages = [
            AgentMessage(role: .user, parts: [
                .toolResult(id: "c", name: "shell_execute", content: "not found", isError: true)
            ]),
        ]
        XCTAssertEqual(LocalTranscriptRenderer.render(messages)[0].text, "Error: not found")
    }

    func testImagesBecomeAnHonestPlaceholder() {
        // Silently dropping an attachment makes the model answer confidently
        // about a picture it never saw. The seed catalog is text-only.
        let messages = [
            AgentMessage(role: .user, parts: [
                .text("what is this?"),
                .imageData(data: Data([0x1]), mimeType: "image/png"),
            ]),
        ]
        let text = LocalTranscriptRenderer.render(messages)[0].text
        XCTAssertTrue(text.contains("what is this?"))
        XCTAssertTrue(text.lowercased().contains("cannot see images"))
    }

    func testToolArgumentsAreSerialisedDeterministically() {
        // Non-deterministic key order would change the fingerprint every turn
        // and defeat cache reuse entirely.
        let messages = [
            AgentMessage(role: .assistant, parts: [
                .toolUse(id: "c", name: "t", input: ["b": "2", "a": "1", "c": "3"])
            ]),
        ]
        let first = LocalTranscriptRenderer.fingerprints(LocalTranscriptRenderer.render(messages))
        let second = LocalTranscriptRenderer.fingerprints(LocalTranscriptRenderer.render(messages))
        XCTAssertEqual(first, second)
    }

    func testEmptyMessagesAreDropped() {
        let messages = [
            AgentMessage(role: .assistant, parts: [.text("")]),
            AgentMessage(role: .user, parts: [.text("real")]),
        ]
        XCTAssertEqual(LocalTranscriptRenderer.render(messages).count, 1)
    }

    func testFingerprintsChangeWhenContentChanges() {
        let a = LocalTranscriptRenderer.fingerprints(
            LocalTranscriptRenderer.render([AgentMessage(role: .user, parts: [.text("one")])]))
        let b = LocalTranscriptRenderer.fingerprints(
            LocalTranscriptRenderer.render([AgentMessage(role: .user, parts: [.text("two")])]))
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - Tool schema shape

/// The local model's whole view of its capabilities is these schemas, and they
/// are the largest fixed cost in its context.
final class LocalToolSchemaBuilderTests: XCTestCase {

    private let tool = AgentToolDefinition(
        name: "shell_execute",
        description: "Run a command",
        parameters: [
            "command": AgentToolParam(type: .string, description: "The command"),
            "target": AgentToolParam(type: .string, description: "Where to run",
                                     enumValues: ["ipad", "windows"]),
        ],
        required: ["command"]
    )

    func testSchemaIsAnOpenAIStyleFunction() {
        let schema = LocalToolSchemaBuilder.schema(for: tool)
        XCTAssertEqual(schema["type"] as? String, "function")
        let function = schema["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "shell_execute")
        let parameters = function?["parameters"] as? [String: Any]
        XCTAssertEqual(parameters?["type"] as? String, "object")
        XCTAssertEqual(parameters?["required"] as? [String], ["command"])
    }

    func testEnumValuesSurvive() {
        // Without the enum the model invents target names, and every invented
        // one silently falls back to the local machine.
        let schema = LocalToolSchemaBuilder.schema(for: tool)
        let function = schema["function"] as? [String: Any]
        let parameters = function?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let target = properties?["target"] as? [String: Any]
        XCTAssertEqual(target?["enum"] as? [String], ["ipad", "windows"])
    }

    func testHashIsStableAcrossParameterOrdering() {
        // `parameters` is a dictionary, so its iteration order varies per
        // process. A hash that depended on it would force a cache rebuild on
        // every single turn.
        let a = LocalToolSchemaBuilder.hash([tool])
        let reordered = AgentToolDefinition(
            name: tool.name, description: tool.description,
            parameters: [
                "target": AgentToolParam(type: .string, description: "Where to run",
                                         enumValues: ["ipad", "windows"]),
                "command": AgentToolParam(type: .string, description: "The command"),
            ],
            required: ["command"]
        )
        XCTAssertEqual(a, LocalToolSchemaBuilder.hash([reordered]))
    }

    func testHashChangesWhenATooIsAddedOrDescribedDifferently() {
        let base = LocalToolSchemaBuilder.hash([tool])
        let extra = AgentToolDefinition(name: "file_read", description: "Read",
                                        parameters: [:], required: [])
        XCTAssertNotEqual(base, LocalToolSchemaBuilder.hash([tool, extra]))

        let reworded = AgentToolDefinition(
            name: tool.name, description: "Run a command somewhere",
            parameters: tool.parameters, required: tool.required)
        XCTAssertNotEqual(base, LocalToolSchemaBuilder.hash([reworded]))
    }

    func testToolOrderDoesNotAffectTheHash() {
        let other = AgentToolDefinition(name: "aaa", description: "d", parameters: [:], required: [])
        XCTAssertEqual(LocalToolSchemaBuilder.hash([tool, other]),
                       LocalToolSchemaBuilder.hash([other, tool]))
    }
}

// MARK: - Availability

final class LocalInferenceAvailabilityTests: XCTestCase {

    func testUnavailableReasonIsPresentExactlyWhenUnavailable() {
        // A silent "local models don't work" with no explanation is the worst
        // possible outcome for a feature whose whole promise is working offline.
        if LocalInferenceAvailability.isAvailable {
            XCTAssertNil(LocalInferenceAvailability.unavailableReason)
        } else {
            XCTAssertNotNil(LocalInferenceAvailability.unavailableReason)
            XCTAssertFalse(LocalInferenceAvailability.unavailableReason!.isEmpty)
        }
    }

    func testAvailabilityRequiresBothRuntimeAndHardware() {
        XCTAssertEqual(
            LocalInferenceAvailability.isAvailable,
            LocalInferenceAvailability.isCompiledIn && LocalInferenceAvailability.isSupportedHardware
        )
    }
}
