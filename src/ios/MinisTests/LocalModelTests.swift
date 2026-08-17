import XCTest

// MARK: - Compatibility

/// Coverage for the rule that a local model is never offered unless we can show
/// it will load.
///
/// Each verdict below corresponds to a real way an on-device model download can
/// waste several gigabytes of a metered connection and then fail.
final class LocalModelCompatibilityTests: XCTestCase {

    private let budget: Int64 = 8_000_000_000   // ~8 GB

    private func files(
        _ names: [String], bytes: Int64? = nil
    ) -> HFRepoFiles {
        HFRepoFiles(filenames: names, totalBytes: bytes)
    }

    private let mlxFiles = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]

    private func config(_ type: String?, bits: Int? = 4) -> HFModelConfig {
        HFModelConfig(
            modelType: type,
            quantization: bits.map { HFModelConfig.Quantization(bits: $0, groupSize: 64) },
            hiddenSize: 2560, numHiddenLayers: 36, maxPositionEmbeddings: nil
        )
    }

    // MARK: The three target models

    func testQwen35IsSupported() {
        // `qwen3_5` is registered in MLXLLM's architecture table.
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen3_5"),
            files: files(mlxFiles, bytes: 3_061_130_647),
            memoryBudgetBytes: budget
        )
        XCTAssertEqual(verdict, .supported)
    }

    func testGemma4IsSupported() {
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("gemma4"),
            files: files(mlxFiles, bytes: 3_583_088_661),
            memoryBudgetBytes: budget
        )
        XCTAssertEqual(verdict, .supported)
    }

    func testUnknownArchitectureIsRefusedWithItsName() {
        // A brand-new release appears on Hugging Face weeks before MLX supports
        // it. Downloading 6 GB to find out is the experience this prevents.
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen9_brandnew"),
            files: files(mlxFiles, bytes: 1_000_000_000),
            memoryBudgetBytes: budget
        )
        XCTAssertEqual(verdict, .unsupportedArchitecture("qwen9_brandnew"))
        XCTAssertTrue(verdict.explanation.contains("qwen9_brandnew"))
    }

    // MARK: Format

    func testGGUFOnlyRepoIsRefusedWithAnExplanation() {
        // The trap: a GGUF a user already downloaded for another app looks
        // interchangeable in a file browser and is not.
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen3_5"),
            files: files(["config.json", "model-q4.gguf", "tokenizer.json"], bytes: 2_000_000_000),
            memoryBudgetBytes: budget
        )
        guard case .notMLXFormat(let reason) = verdict else {
            return XCTFail("a GGUF-only repo must be refused, got \(verdict)")
        }
        XCTAssertTrue(reason.contains("GGUF"))
        XCTAssertTrue(verdict.explanation.contains("GGUF"))
    }

    func testRepoWithoutWeightsIsRefused() {
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen3_5"),
            files: files(["README.md", "config.json"], bytes: 1000),
            memoryBudgetBytes: budget
        )
        guard case .notMLXFormat = verdict else { return XCTFail("got \(verdict)") }
    }

    func testRepoWithoutTokenizerIsRefused() {
        // Weights without a tokenizer load into a model that can't be prompted.
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen3_5"),
            files: files(["config.json", "model.safetensors"], bytes: 1_000_000),
            memoryBudgetBytes: budget
        )
        guard case .notMLXFormat(let reason) = verdict else { return XCTFail("got \(verdict)") }
        XCTAssertTrue(reason.contains("tokenizer"))
    }

    func testMissingConfigIsUnknownNotSupported() {
        // "Couldn't check" must never be reported as "works".
        let verdict = LocalModelCompatibilityChecker.check(
            config: nil, files: files(mlxFiles, bytes: 1_000_000), memoryBudgetBytes: budget)
        guard case .unknown = verdict else { return XCTFail("got \(verdict)") }
        XCTAssertFalse(verdict.isSupported)
    }

    // MARK: Size

    func testModelTooLargeForTheDeviceIsRefusedWithNumbers() {
        // A 9B 4-bit model on a device with a small budget. The user can act on
        // this verdict by choosing a smaller quantization, so the numbers are
        // part of the message.
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen3_5"),
            files: files(mlxFiles, bytes: 5_977_073_303),
            memoryBudgetBytes: 4_000_000_000
        )
        guard case .tooLargeForDevice(let required, let budget) = verdict else {
            return XCTFail("got \(verdict)")
        }
        XCTAssertGreaterThan(required, 5.9)
        XCTAssertEqual(budget, 4.0, accuracy: 0.01)
        XCTAssertTrue(verdict.explanation.contains("GB"))
    }

    func testPeakEstimateExceedsWeightsBecauseOfCacheAndActivations() {
        // Being optimistic here means an OOM kill mid-generation, which loses
        // the user's whole turn.
        let weights: Int64 = 3_000_000_000
        let peak = LocalModelCompatibilityChecker.estimatedPeakBytes(weightBytes: weights)
        XCTAssertGreaterThan(peak, weights)
        XCTAssertGreaterThan(peak, Int64(Double(weights) * 1.3))
    }

    func testUnknownSizeDoesNotBlockAModel() {
        // No size reported is not evidence of being too big.
        let verdict = LocalModelCompatibilityChecker.check(
            config: config("qwen3_5"), files: files(mlxFiles, bytes: nil),
            memoryBudgetBytes: 1_000_000
        )
        XCTAssertEqual(verdict, .supported)
    }

    // MARK: Memory budget

    func testBudgetIsWellBelowPhysicalRAM() {
        // iOS kills a process well before it reaches physical RAM.
        let ram: Int64 = 16_000_000_000
        let budget = LocalModelMemoryBudget.estimatedBudget(physicalMemory: ram)
        XCTAssertLessThan(budget, ram)
        XCTAssertGreaterThan(budget, ram / 3)
    }

    func testIncreasedMemoryLimitEntitlementRaisesTheBudget() {
        let ram: Int64 = 16_000_000_000
        XCTAssertGreaterThan(
            LocalModelMemoryBudget.estimatedBudget(physicalMemory: ram, hasIncreasedMemoryLimit: true),
            LocalModelMemoryBudget.estimatedBudget(physicalMemory: ram)
        )
    }
}

// MARK: - Catalog

final class LocalModelCatalogTests: XCTestCase {

    func testSeedEntriesUseSupportedArchitectures() {
        // Every shipped suggestion must be one MLXLLM can actually build; the
        // architecture family is derivable from the repo name for these.
        for entry in LocalModelCatalog.seed {
            let name = entry.repoID.lowercased()
            let family = name.contains("qwen3.5") ? "qwen3_5"
                       : name.contains("gemma-4") ? "gemma4" : ""
            XCTAssertTrue(MLXArchitectureSupport.isSupported(modelType: family),
                          "\(entry.repoID) maps to unsupported architecture '\(family)'")
        }
    }

    func testSeedEntriesCarryRealSizes() {
        // A picker that can't show a download size in advance is how a user
        // ends up spending 6 GB of cellular data by accident.
        for entry in LocalModelCatalog.seed {
            XCTAssertNotNil(entry.downloadSizeText, "\(entry.repoID) has no size")
            XCTAssertGreaterThan(entry.downloadBytes ?? 0, 500_000_000)
        }
    }

    func testAppModelIDsAreNamespacedAndUnique() {
        // A local model id must never collide with a remote provider's.
        let ids = LocalModelCatalog.seed.map(\.appModelID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("local/") })
    }

    func testRepoIDNormalisationAcceptsWhatPeopleActuallyPaste() {
        let expected = "mlx-community/Qwen3.5-4B-4bit"
        XCTAssertEqual(LocalModelCatalog.normalizeRepoID(expected), expected)
        XCTAssertEqual(
            LocalModelCatalog.normalizeRepoID("https://huggingface.co/mlx-community/Qwen3.5-4B-4bit"),
            expected)
        XCTAssertEqual(
            LocalModelCatalog.normalizeRepoID("huggingface.co/mlx-community/Qwen3.5-4B-4bit/tree/main"),
            expected)
        XCTAssertEqual(LocalModelCatalog.normalizeRepoID("  mlx-community/Qwen3.5-4B-4bit/ "), expected)
    }

    func testRepoIDNormalisationRejectsGarbage() {
        XCTAssertNil(LocalModelCatalog.normalizeRepoID("notarepo"))
        XCTAssertNil(LocalModelCatalog.normalizeRepoID("a/b/c"))
        XCTAssertNil(LocalModelCatalog.normalizeRepoID(""))
        XCTAssertNil(LocalModelCatalog.normalizeRepoID("../../etc/passwd"))
        XCTAssertNil(LocalModelCatalog.normalizeRepoID("owner/name with spaces"))
    }

    func testConfigJSONDecodesTheRealShape() throws {
        // The literal shape returned by mlx-community/Qwen3.5-4B-4bit.
        let json = """
        {"model_type":"qwen3_5","hidden_size":2560,"num_hidden_layers":36,
         "quantization":{"bits":4,"group_size":64}}
        """
        let config = try HFModelConfig.decode(Data(json.utf8))
        XCTAssertEqual(config.modelType, "qwen3_5")
        XCTAssertEqual(config.quantization?.bits, 4)
        XCTAssertEqual(config.quantization?.groupSize, 64)
    }

    func testConfigJSONToleratesUnknownFields() {
        // Real config.json files carry dozens of fields we don't model; a
        // strict decode would reject every one of them.
        let json = #"{"model_type":"gemma4","some_new_field":{"a":1},"rope_scaling":null}"#
        XCTAssertEqual(try? HFModelConfig.decode(Data(json.utf8)).modelType, "gemma4")
    }
}

// MARK: - Tool-call salvage

/// Coverage for recovering tool calls a small model nearly got right.
///
/// Every input below is a shape small models actually produce. The cost of not
/// recovering is a full round trip at ~15 tok/s — 30+ seconds of visible
/// nothing — and the retry often reproduces the same mistake.
final class LocalToolCallSalvageTests: XCTestCase {

    // MARK: Well-formed

    func testWellFormedHermesCall() {
        let raw = #"<tool_call>{"name": "shell_execute", "arguments": {"command": "ls -la"}}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "shell_execute")
        XCTAssertEqual(calls[0].arguments["command"], .string("ls -la"))
        XCTAssertTrue(calls[0].repairs.isEmpty, "clean input must not be 'repaired'")
    }

    func testMultipleCallsInOneTurn() {
        let raw = """
        <tool_call>{"name": "file_read", "arguments": {"path": "/a"}}</tool_call>
        <tool_call>{"name": "file_read", "arguments": {"path": "/b"}}</tool_call>
        """
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].arguments["path"], .string("/b"))
    }

    func testNoToolCallReturnsNothing() {
        XCTAssertTrue(LocalToolCallSalvage.salvage(from: "Sure, I'll do that.").isEmpty)
        XCTAssertTrue(LocalToolCallSalvage.salvage(from: "").isEmpty)
    }

    func testJSONThatIsNotAToolCallIsNotExecuted() {
        // A model answering a question *about* JSON must not have its answer
        // executed as a tool call.
        let raw = #"Here's an example config: {"host": "localhost", "port": 8080}"#
        XCTAssertTrue(LocalToolCallSalvage.salvage(from: raw).isEmpty)
    }

    // MARK: Wrapper repairs

    func testUnterminatedTagIsRecovered() {
        // The model hit its token limit right after the arguments closed.
        let raw = #"<tool_call>{"name": "shell_execute", "arguments": {"command": "pwd"}}"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments["command"], .string("pwd"))
        XCTAssertTrue(calls[0].repairs.contains("unterminated-tool_call-tag"))
    }

    func testMarkdownFencedCall() {
        let raw = """
        I'll list the files.
        ```json
        {"name": "shell_execute", "arguments": {"command": "ls"}}
        ```
        """
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].repairs.contains("markdown-fence"))
    }

    func testBareObjectWithToolCallKeys() {
        let raw = #"{"name": "file_read", "arguments": {"path": "/etc/hosts"}}"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "file_read")
    }

    func testSurroundingProseIsStripped() {
        let raw = #"<tool_call>Here you go: {"name": "x", "arguments": {}} hope that helps</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.name, "x")
        XCTAssertTrue(calls.first?.repairs.contains("stripped-surrounding-prose") ?? false)
    }

    // MARK: Argument shape repairs

    func testStringifiedArguments() {
        // Extremely common: the model JSON-encodes the arguments object into a
        // string, imitating the OpenAI wire format.
        let raw = #"<tool_call>{"name": "shell_execute", "arguments": "{\"command\": \"ls\"}"}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.arguments["command"], .string("ls"))
        XCTAssertTrue(calls.first?.repairs.contains("stringified-arguments") ?? false)
    }

    func testParametersKeyAlias() {
        let raw = #"<tool_call>{"name": "shell_execute", "parameters": {"command": "ls"}}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.arguments["command"], .string("ls"))
        XCTAssertTrue(calls.first?.repairs.contains("arguments-key-alias") ?? false)
    }

    func testOpenAIFunctionWrapper() {
        let raw = #"<tool_call>{"function": {"name": "file_read", "arguments": {"path": "/x"}}}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.name, "file_read")
        XCTAssertEqual(calls.first?.arguments["path"], .string("/x"))
    }

    func testMissingArgumentsDefaultsToEmpty() {
        // Legitimate for a zero-parameter tool; upstream validation still
        // rejects it if the tool actually requires arguments.
        let raw = #"<tool_call>{"name": "list_sessions", "arguments": {}}</tool_call>"#
        XCTAssertEqual(LocalToolCallSalvage.salvage(from: raw).first?.arguments, [:])
    }

    // MARK: JSON repairs

    func testTrailingCommaPayloadIsSalvaged() {
        // Asserts the OUTCOME, not the mechanism. Swift 6's Foundation JSON
        // parser already tolerates trailing commas, so on that toolchain the
        // strict decode succeeds and the repair pass never runs. The repair
        // still has to exist — Apple's older parser rejects them, and so does
        // any host whose Foundation predates the lenient parser — but a test
        // that pinned "the repair fired" would fail on exactly the platform
        // where the input needs no repairing.
        let raw = #"<tool_call>{"name": "x", "arguments": {"a": 1,},}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.name, "x")
        XCTAssertEqual(calls.first?.arguments["a"], .int(1))
    }

    func testTrailingCommaRepairProducesStrictJSON() {
        // The repair itself, tested directly, so its correctness doesn't depend
        // on how lenient the host's decoder happens to be.
        let repaired = LocalToolCallSalvage.removeTrailingCommas(#"{"a": 1,},"#)
        XCTAssertEqual(repaired, #"{"a": 1}"#)
        XCTAssertNil(LocalToolCallSalvage.removeTrailingCommas(#"{"a": 1}"#),
                     "clean input reports no change")
    }

    func testTrailingCommaRepairPreservesCommasInsideStrings() {
        // The repair must not touch a comma that is part of an argument value —
        // a shell command with a comma in it is completely ordinary.
        let input = #"{"name": "x", "arguments": {"command": "a,b,c",}}"#
        let repaired = LocalToolCallSalvage.removeTrailingCommas(input)!
        XCTAssertTrue(repaired.contains(#""a,b,c""#))
        XCTAssertFalse(repaired.contains(",}"))
    }

    func testSingleQuotedPayload() {
        let raw = "<tool_call>{'name': 'shell_execute', 'arguments': {'command': 'ls'}}</tool_call>"
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.name, "shell_execute")
        XCTAssertTrue(calls.first?.repairs.contains("single-quotes") ?? false)
    }

    func testMixedQuotesAreNotRewritten() {
        // The safety rule: an apostrophe inside a double-quoted value ("don't")
        // must never be turned into a quote character.
        let mixed = #"{"name": "x", "arguments": {"msg": "don't"}}"#
        XCTAssertNil(LocalToolCallSalvage.convertSingleQuotedKeys(mixed))
    }

    func testPythonLiterals() {
        let raw = #"<tool_call>{"name": "file_write", "arguments": {"path": "/x", "append": True, "extra": None}}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.arguments["append"], .bool(true))
        XCTAssertEqual(calls.first?.arguments["extra"], .null)
        XCTAssertTrue(calls.first?.repairs.contains("python-literals") ?? false)
    }

    func testPythonLiteralRepairLeavesStringContentAlone() {
        // "None" as a legitimate argument value must survive.
        let input = #"{"name": "x", "arguments": {"mode": "None", "flag": True}}"#
        let repaired = LocalToolCallSalvage.replacePythonLiterals(input)!
        XCTAssertTrue(repaired.contains(#""None""#))
        XCTAssertTrue(repaired.contains("true"))
    }

    func testTruncatedObjectIsClosed() {
        let raw = #"<tool_call>{"name": "shell_execute", "arguments": {"command": "ls"}"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        XCTAssertEqual(calls.first?.arguments["command"], .string("ls"))
    }

    func testTruncationInsideAStringIsRefused() {
        // The important negative. Completing a half-written command would hand
        // a WRONG argument to a tool that then runs it — much worse than losing
        // the turn.
        XCTAssertNil(LocalToolCallSalvage.closeUnbalancedBraces(
            #"{"name": "shell_execute", "arguments": {"command": "rm -rf /ho"#))
    }

    func testDanglingKeyIsRefused() {
        XCTAssertNil(LocalToolCallSalvage.closeUnbalancedBraces(#"{"name": "x", "arguments":"#))
    }

    func testAlreadyBalancedIsNotTouched() {
        XCTAssertNil(LocalToolCallSalvage.closeUnbalancedBraces(#"{"a": 1}"#))
    }

    // MARK: Balanced-object scanner

    func testBalancedScannerRespectsBracesInsideStrings() {
        // A shell command containing `}` is ordinary and must not end the
        // object early.
        let text = #"{"name": "x", "arguments": {"command": "awk '{print $1}'"}} trailing"#
        let object = LocalToolCallSalvage.firstBalancedObject(in: text)
        XCTAssertEqual(object, #"{"name": "x", "arguments": {"command": "awk '{print $1}'"}}"#)
    }

    func testBalancedScannerRespectsEscapedQuotes() {
        let text = #"{"a": "say \"hi\"", "b": 1} rest"#
        XCTAssertEqual(LocalToolCallSalvage.firstBalancedObject(in: text), #"{"a": "say \"hi\"", "b": 1}"#)
    }

    // MARK: Markup stripping

    func testMarkupIsStrippedFromVisibleText() {
        // Otherwise the user sees raw `<tool_call>` JSON next to the rendered
        // tool card, which reads as a broken app.
        let raw = #"Let me check. <tool_call>{"name":"x","arguments":{}}</tool_call> Done."#
        XCTAssertEqual(LocalToolCallSalvage.strippingToolCallMarkup(raw), "Let me check.  Done.")
    }

    func testUnterminatedMarkupIsStrippedToTheEnd() {
        let raw = #"Working on it. <tool_call>{"name":"x""#
        XCTAssertEqual(LocalToolCallSalvage.strippingToolCallMarkup(raw), "Working on it.")
    }

    // MARK: Safety invariants

    func testSalvageNeverInventsAToolName() {
        // No repair may fabricate a call. Payloads with no name must produce
        // nothing at all.
        for raw in [
            #"<tool_call>{"arguments": {"command": "rm -rf /"}}</tool_call>"#,
            #"<tool_call>{}</tool_call>"#,
            "<tool_call>not json at all</tool_call>",
            #"<tool_call>{"name": ""}</tool_call>"#,
        ] {
            XCTAssertTrue(LocalToolCallSalvage.salvage(from: raw).isEmpty, "recovered from: \(raw)")
        }
    }

    func testSalvageNeverInventsAnArgumentValue() {
        let raw = #"<tool_call>{"name": "shell_execute", "arguments": {"command": ""}}</tool_call>"#
        let calls = LocalToolCallSalvage.salvage(from: raw)
        // The empty command survives as empty — upstream preflight rejects it
        // with a message the model can act on. Filling it in would be worse.
        XCTAssertEqual(calls.first?.arguments["command"], .string(""))
    }
}
