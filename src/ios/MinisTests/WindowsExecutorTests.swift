import XCTest

// MARK: - Test fixtures

/// Recorded `tools/list` payloads from real Desktop Commander shapes.
///
/// The point of the adapter is that we do NOT control the endpoint — it is the
/// user's own build. These fixtures encode the shapes we have to survive: the
/// compact five-tool surface the user runs, the full upstream surface, a fork
/// with renamed tools, and a degenerate endpoint with only a shell.
private enum Fixtures {

    static func tool(_ name: String, _ params: [String], required: [String] = [], types: [String: String] = [:]) -> MCPToolDescriptor {
        MCPToolDescriptor(
            name: name,
            description: "",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(Dictionary(uniqueKeysWithValues:
                    params.map { ($0, MCPValue.object(["type": .string(types[$0] ?? "string")])) })),
                "required": .array(required.map { .string($0) }),
            ])
        )
    }

    /// The user's stated compact surface: start_process, interact_with_process,
    /// read_process_output, read_file, apply_patch. Note there is no
    /// `write_file` — writes have to be emulated.
    static let compact: [MCPToolDescriptor] = [
        tool("start_process", ["command", "timeout_ms", "shell"], required: ["command"]),
        tool("read_process_output", ["pid", "timeout_ms"], required: ["pid"]),
        tool("interact_with_process", ["pid", "input", "timeout_ms"], required: ["pid", "input"]),
        tool("read_file", ["path", "offset", "length"], required: ["path"]),
        tool("apply_patch", ["path", "old_string", "new_string", "replace_all"],
             required: ["path", "old_string", "new_string"]),
    ]

    /// Upstream Desktop Commander, abridged to the tools that matter here.
    static let full: [MCPToolDescriptor] = compact + [
        tool("write_file", ["path", "content", "mode"], required: ["path", "content"]),
        tool("force_terminate", ["pid"], required: ["pid"]),
        tool("list_directory", ["path"], required: ["path"]),
        tool("search_code", ["path", "pattern"], required: ["path", "pattern"]),
        tool("get_config", []),
    ]

    /// Desktop Commander 0.2.47 as exposed by the real :8765 MCP.
    /// Its Codex-style `apply_patch` is not MiniPad's string-replacement verb,
    /// and all process tools require a numeric pid.
    static let desktopCommander0247: [MCPToolDescriptor] = [
        tool("start_process", ["command", "cwd", "timeout_ms"], required: ["command"],
             types: ["timeout_ms": "number"]),
        tool("read_process_output", ["pid", "length", "offset", "timeout_ms"], required: ["pid"],
             types: ["pid": "number", "length": "number", "offset": "number", "timeout_ms": "number"]),
        tool("interact_with_process", ["pid", "input", "timeout_ms"], required: ["pid", "input"],
             types: ["pid": "number", "timeout_ms": "number"]),
        tool("force_terminate", ["pid"], required: ["pid"], types: ["pid": "number"]),
        tool("read_file", ["path", "offset", "length"], required: ["path"],
             types: ["offset": "number", "length": "number"]),
        tool("write_file", ["path", "content", "mode"], required: ["path", "content"]),
        tool("apply_patch", ["patch", "cwd", "check"], required: ["patch"], types: ["check": "boolean"]),
        tool("edit_block", ["file_path", "old_string", "new_string", "expected_replacements"],
             required: ["file_path"], types: ["expected_replacements": "number"]),
    ]

    /// A fork that renamed everything and uses seconds for timeouts.
    static let renamed: [MCPToolDescriptor] = [
        tool("run_command", ["cmd", "timeout_seconds", "cwd"], required: ["cmd"]),
        tool("get_process_output", ["process_id"], required: ["process_id"]),
        tool("send_input", ["process_id", "text"], required: ["process_id", "text"]),
        tool("read_text_file", ["file_path"], required: ["file_path"]),
        tool("edit_block", ["file_path", "old_string", "new_string"],
             required: ["file_path", "old_string", "new_string"]),
    ]

    /// Shell only.
    static let shellOnly: [MCPToolDescriptor] = [
        tool("start_process", ["command"], required: ["command"]),
    ]
}

// MARK: - Adapter

/// Coverage for binding the endpoint's tools onto the unified verbs.
///
/// A wrong binding here runs the wrong operation on the user's PC — the worst
/// class of bug this integration can produce — so the tests lean hard on the
/// "ambiguity must lose to not-bound" rule.
final class DesktopCommanderAdapterTests: XCTestCase {

    func testCompactSurfaceBindsNativelyAndEmulatesTheRest() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.compact)

        XCTAssertEqual(caps.binding(.startProcess)?.toolName, "start_process")
        XCTAssertEqual(caps.binding(.readProcessOutput)?.toolName, "read_process_output")
        XCTAssertEqual(caps.binding(.interactWithProcess)?.toolName, "interact_with_process")
        XCTAssertEqual(caps.binding(.readFile)?.toolName, "read_file")
        XCTAssertEqual(caps.binding(.applyPatch)?.toolName, "apply_patch")

        // No write_file and no terminate in this build — both are shell-
        // emulatable, so they must be emulated rather than reported missing.
        XCTAssertTrue(caps.emulated.contains(.writeFile))
        XCTAssertTrue(caps.emulated.contains(.terminateProcess))
        XCTAssertTrue(caps.missing.isEmpty, "everything unbound here is emulatable")

        XCTAssertTrue(caps.canRunCommands)
        XCTAssertTrue(caps.supportsInteractiveProcesses)
    }

    func testFullSurfaceBindsEverythingNatively() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.full)
        for verb in RemoteVerb.allCases {
            XCTAssertNotNil(caps.binding(verb), "\(verb) should bind natively")
        }
        XCTAssertTrue(caps.emulated.isEmpty)
        XCTAssertTrue(caps.missing.isEmpty)
    }

    func testDesktopCommander0247UsesEditBlockInsteadOfCodexApplyPatch() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.desktopCommander0247)
        XCTAssertEqual(caps.binding(.applyPatch)?.toolName, "edit_block")
        XCTAssertEqual(caps.binding(.terminateProcess)?.toolName, "force_terminate")
        XCTAssertTrue(caps.supportsInteractiveProcesses)
        XCTAssertTrue(caps.missing.isEmpty)
    }

    func testDesktopCommander0247CoercesOpaquePIDToNumber() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.desktopCommander0247)
        let read = caps.binding(.readProcessOutput)!
        let interact = caps.binding(.interactWithProcess)!
        let terminate = caps.binding(.terminateProcess)!
        XCTAssertEqual(read.arguments([.processID: .string("41208")])["pid"], .int(41208))
        XCTAssertEqual(interact.arguments([.processID: .string("41208")])["pid"], .int(41208))
        XCTAssertEqual(terminate.arguments([.processID: .string("41208")])["pid"], .int(41208))
    }

    func testExpectedReplacementsIsNotTreatedAsReplaceAllBoolean() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.desktopCommander0247)
        let patch = caps.binding(.applyPatch)!
        XCTAssertEqual(patch.toolName, "edit_block")
        XCTAssertNil(patch.name(for: .replaceAll))
    }

    func testRenamedForkStillBinds() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.renamed)
        XCTAssertEqual(caps.binding(.startProcess)?.toolName, "run_command")
        XCTAssertEqual(caps.binding(.readProcessOutput)?.toolName, "get_process_output")
        XCTAssertEqual(caps.binding(.interactWithProcess)?.toolName, "send_input")
        XCTAssertEqual(caps.binding(.readFile)?.toolName, "read_text_file")
        XCTAssertEqual(caps.binding(.applyPatch)?.toolName, "edit_block")
    }

    func testArgumentNamesAreMappedNotAssumed() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.renamed)
        let start = caps.binding(.startProcess)
        XCTAssertEqual(start?.name(for: .command), "cmd")
        XCTAssertEqual(start?.name(for: .workingDirectory), "cwd")

        let interact = caps.binding(.interactWithProcess)
        XCTAssertEqual(interact?.name(for: .processID), "process_id")
        XCTAssertEqual(interact?.name(for: .input), "text")
    }

    func testTimeoutUnitIsDerivedFromTheParameterName() {
        // Sending seconds where the endpoint expects milliseconds truncates a
        // build log; the reverse wastes a wait. Neither is guessable at the
        // call site, so it's derived from the declared name.
        let compact = DesktopCommanderAdapter.resolve(tools: Fixtures.compact)
        XCTAssertTrue(compact.binding(.startProcess)?.timeoutIsMilliseconds ?? false)

        let renamed = DesktopCommanderAdapter.resolve(tools: Fixtures.renamed)
        XCTAssertFalse(renamed.binding(.startProcess)?.timeoutIsMilliseconds ?? true)
    }

    func testBareTimeoutDefaultsToMilliseconds() {
        XCTAssertTrue(RemoteArg.timeoutIsMilliseconds(parameterName: "timeout"))
        XCTAssertTrue(RemoteArg.timeoutIsMilliseconds(parameterName: "timeout_ms"))
        XCTAssertFalse(RemoteArg.timeoutIsMilliseconds(parameterName: "timeout_seconds"))
        XCTAssertFalse(RemoteArg.timeoutIsMilliseconds(parameterName: "timeout_sec"))
    }

    func testShellOnlyEndpointEmulatesFilesButHasNoInteractiveProcesses() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.shellOnly)
        XCTAssertTrue(caps.canRunCommands)
        XCTAssertFalse(caps.supportsInteractiveProcesses)
        XCTAssertTrue(caps.emulated.contains(.readFile))
        XCTAssertTrue(caps.emulated.contains(.writeFile))
        XCTAssertTrue(caps.emulated.contains(.applyPatch))
        // These cannot be faked over a shell — reading and writing a running
        // process's pipes needs the endpoint's own process table.
        XCTAssertTrue(caps.missing.contains(.readProcessOutput))
        XCTAssertTrue(caps.missing.contains(.interactWithProcess))
    }

    func testEmptyEndpointReportsNoExecutionRatherThanPretending() {
        let caps = DesktopCommanderAdapter.resolve(tools: [])
        XCTAssertFalse(caps.canRunCommands)
        XCTAssertTrue(caps.missing.contains(.startProcess))
        // Nothing is emulatable without a shell to emulate over.
        XCTAssertTrue(caps.emulated.isEmpty)
    }

    func testOneToolIsNeverBoundToTwoVerbs() {
        // `read_file` matching both readFile and readProcessOutput would make
        // a poll read a file forever.
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.full)
        let names = RemoteVerb.allCases.compactMap { caps.binding($0)?.toolName }
        XCTAssertEqual(Set(names).count, names.count, "duplicate binding: \(names)")
    }

    func testAmbiguousShapeMatchIsRefused() {
        // Two unnamed candidates with the same shape: binding either would be a
        // coin flip on the user's PC, so bind neither.
        let ambiguous = [
            Fixtures.tool("do_thing_a", ["command"], required: ["command"]),
            Fixtures.tool("do_thing_b", ["command"], required: ["command"]),
        ]
        let caps = DesktopCommanderAdapter.resolve(tools: ambiguous)
        XCTAssertNil(caps.binding(.startProcess))
    }

    func testUnambiguousShapeMatchIsAccepted() {
        let renamedBeyondRecognition = [
            Fixtures.tool("zzz_shell", ["command", "cwd"], required: ["command"]),
        ]
        let caps = DesktopCommanderAdapter.resolve(tools: renamedBeyondRecognition)
        XCTAssertEqual(caps.binding(.startProcess)?.toolName, "zzz_shell")
    }

    func testArgumentsDropParametersTheToolDoesNotDeclare() {
        // A strict server rejects unknown properties; sending `cwd` to a tool
        // with no `cwd` would fail every call on that endpoint.
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.shellOnly)
        let args = caps.binding(.startProcess)!.arguments([
            .command: .string("dir"),
            .workingDirectory: .string("C:\\"),
            .timeoutMS: .int(1000),
        ])
        XCTAssertEqual(args, ["command": .string("dir")])
    }

    func testSummaryDescribesTheEndpointHonestly() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.shellOnly)
        XCTAssertTrue(caps.summary.contains("emulated"))
        XCTAssertTrue(caps.summary.contains("unavailable"))
    }

    func testDiscoveredToolNamesAreRecordedForDiagnostics() {
        let caps = DesktopCommanderAdapter.resolve(tools: Fixtures.full)
        XCTAssertTrue(caps.discoveredToolNames.contains("search_code"))
        XCTAssertEqual(caps.discoveredToolNames, caps.discoveredToolNames.sorted())
    }
}

// MARK: - Shell emulation

final class WindowsShellEmulationTests: XCTestCase {

    func testSingleQuotingEscapesEmbeddedQuotes() {
        // The only escape inside a PowerShell single-quoted literal is ''.
        // Getting this wrong turns a filename into executable code.
        XCTAssertEqual(WindowsShellEmulation.singleQuoted("C:\\a b"), "'C:\\a b'")
        XCTAssertEqual(WindowsShellEmulation.singleQuoted("it's"), "'it''s'")
    }

    func testWriteCommandCarriesContentAsBase64() {
        // A build log, a Python script and a JSON blob each contain characters
        // that break at least one PowerShell quoting rule. Base64 has exactly
        // one escaping rule and it is "there isn't one".
        let tricky = "line1\n\"quoted\" 'single' `backtick` $var\r\n漢字"
        let command = WindowsShellEmulation.writeFileCommand(path: "C:\\x.txt", contents: Data(tricky.utf8))
        let expected = Data(tricky.utf8).base64EncodedString()
        XCTAssertTrue(command.contains(expected))
        // The raw text must never appear inline.
        XCTAssertFalse(command.contains("$var"))
        XCTAssertTrue(command.contains("New-Item -ItemType Directory"), "parents are created")
    }

    func testPatchCommandRefusesAnEmptyNeedle() {
        // Matching the empty string has no sensible occurrence count and would
        // spin the counting loop forever on the user's PC.
        XCTAssertNil(WindowsShellEmulation.applyPatchCommand(
            path: "C:\\x", oldString: "", newString: "y", replaceAll: false))
    }

    func testPatchCommandAvoidsRegexInterpretation() {
        // `-replace` would treat `.` and `(` as regex metacharacters and edit
        // the wrong text in the user's own repository.
        let command = WindowsShellEmulation.applyPatchCommand(
            path: "C:\\x.py", oldString: "foo(a.b)", newString: "bar", replaceAll: false)!
        XCTAssertFalse(command.contains("-replace"))
        XCTAssertTrue(command.contains("IndexOf"))
        XCTAssertTrue(command.contains(Data("foo(a.b)".utf8).base64EncodedString()))
    }

    func testPatchCommandUsesReplaceOnlyWhenReplacingAll() {
        let all = WindowsShellEmulation.applyPatchCommand(
            path: "C:\\x", oldString: "a", newString: "b", replaceAll: true)!
        XCTAssertTrue(all.contains("$t.Replace($o, $n)"))

        let single = WindowsShellEmulation.applyPatchCommand(
            path: "C:\\x", oldString: "a", newString: "b", replaceAll: false)!
        XCTAssertTrue(single.contains("Remove"))
        XCTAssertTrue(single.contains("Insert"))
    }

    func testPIDSanitisationStripsInjection() {
        // A pid reaches us as an opaque string from the endpoint and is
        // interpolated into a command line. A malicious or buggy endpoint must
        // not be able to append a second statement.
        XCTAssertEqual(WindowsShellEmulation.sanitizePID("41208"), "41208")
        XCTAssertEqual(WindowsShellEmulation.sanitizePID("1; Remove-Item C:\\ -Recurse"), "1")
        XCTAssertEqual(WindowsShellEmulation.sanitizePID("not-a-pid"), "0")
        XCTAssertEqual(WindowsShellEmulation.sanitizePID(""), "0")
    }

    func testTerminateIsIdempotent() {
        // cancel() is documented as idempotent, and Stop-Process on an
        // already-exited pid is an error rather than a no-op.
        let command = WindowsShellEmulation.terminateCommand(pid: "5")
        XCTAssertTrue(command.contains("already-exited"))
    }

    func testOutcomeParsing() {
        XCTAssertEqual(WindowsShellEmulation.parseOutcome("MINIS_OK:42"), .ok(detail: "42"))
        XCTAssertEqual(WindowsShellEmulation.parseOutcome("MINIS_OK"), .ok(detail: ""))
        XCTAssertEqual(WindowsShellEmulation.parseOutcome("MINIS_ERR:nope"), .failed(message: "nope"))
    }

    func testOutcomeParsingSkipsLeadingNoise() {
        // PowerShell prepends progress records and warnings; the marker is the
        // last line, not the only one.
        let output = "WARNING: something\nVERBOSE: other\nMINIS_OK:7"
        XCTAssertEqual(WindowsShellEmulation.parseOutcome(output), .ok(detail: "7"))
    }

    func testMissingMarkerIsAFailureNotASilentSuccess() {
        // No marker means the command didn't reach its epilogue — the shell
        // died or the endpoint truncated. Reporting success there would tell
        // the model a file was written when it wasn't.
        XCTAssertEqual(WindowsShellEmulation.parseOutcome(""),
                       .failed(message: "no output from the remote shell"))
        if case .ok = WindowsShellEmulation.parseOutcome("random text") {
            XCTFail("unmarked output must not be reported as success")
        }
    }
}

// MARK: - Result parsing

final class WindowsResultParserTests: XCTestCase {

    private func result(_ text: String, structured: MCPValue? = nil, isError: Bool = false)
        -> MCPToolCall.Result {
        MCPToolCall.Result(text: text, isError: isError, images: [], structured: structured)
    }

    func testStructuredPIDWinsOverProse() {
        // Prose is the unreliable path; when both are present the structured
        // value is authoritative.
        let r = result("Process started with PID 999", structured: .object(["pid": .int(41208)]))
        XCTAssertEqual(WindowsResultParser.processID(from: r), "41208")
    }

    func testPIDFromCommonProseShapes() {
        XCTAssertEqual(WindowsResultParser.processID(fromText: "Process started with PID 41208"), "41208")
        XCTAssertEqual(WindowsResultParser.processID(fromText: "PID: 41208"), "41208")
        XCTAssertEqual(WindowsResultParser.processID(fromText: "pid=41208"), "41208")
        XCTAssertEqual(WindowsResultParser.processID(fromText: "Started (pid 41208)"), "41208")
    }

    func testPIDIsNotHarvestedFromALaterLine() {
        // The failure this prevents: grabbing an unrelated number from a build
        // log and sending the user's next keystrokes to some other process.
        XCTAssertNil(WindowsResultParser.processID(fromText: "no pid available\nbuilt 1234 files"))
    }

    func testPIDIsNotHarvestedFromFarAway() {
        let text = "pid" + String(repeating: " ", count: 60) + "1234"
        XCTAssertNil(WindowsResultParser.processID(fromText: text))
    }

    func testNoPIDWhenAbsent() {
        XCTAssertNil(WindowsResultParser.processID(fromText: "done"))
    }

    func testExitCodeFromStructuredAndProse() {
        XCTAssertEqual(
            WindowsResultParser.exitCode(from: result("", structured: .object(["exitCode": .int(2)]))), 2)
        XCTAssertEqual(WindowsResultParser.exitCode(fromText: "Process exited with code 1"), 1)
        XCTAssertEqual(WindowsResultParser.exitCode(fromText: "exit code: 0"), 0)
        XCTAssertEqual(WindowsResultParser.exitCode(fromText: "return code -1073741819"), -1073741819)
        XCTAssertNil(WindowsResultParser.exitCode(fromText: "still going"))
    }

    func testLivenessFromStructuredFlag() {
        XCTAssertTrue(WindowsResultParser.isStillRunning(
            result("", structured: .object(["isRunning": .bool(true)]))))
        XCTAssertFalse(WindowsResultParser.isStillRunning(
            result("", structured: .object(["isRunning": .bool(false)]))))
    }

    func testStructuredExitCodeImpliesFinished() {
        XCTAssertFalse(WindowsResultParser.isStillRunning(
            result("still running", structured: .object(["exitCode": .int(0)]))))
    }

    func testLivenessFromProse() {
        XCTAssertTrue(WindowsResultParser.isStillRunning(result("Process started, still running")))
        XCTAssertFalse(WindowsResultParser.isStillRunning(result("Process exited with code 0")))
    }

    func testFinishedPhrasingWinsOverRunningPhrasing() {
        // "running in the background; it has now completed" is a real shape,
        // and the later clause is the authoritative one.
        XCTAssertFalse(WindowsResultParser.isStillRunning(
            result("running in the background — process completed")))
    }

    func testUnknownLivenessDefaultsToFinished() {
        // Safer default: end the call with whatever output arrived, rather than
        // polling a process that may not exist until the timeout expires.
        XCTAssertFalse(WindowsResultParser.isStillRunning(result("something happened")))
    }
}

// MARK: - Output clipping

final class OutputClipperTests: XCTestCase {

    func testShortOutputIsUntouched() {
        let (text, truncated) = OutputClipper.clip("hello", limit: 100)
        XCTAssertEqual(text, "hello")
        XCTAssertFalse(truncated)
    }

    func testLongOutputKeepsBothEnds() {
        // The two informative parts of a build log are the invocation at the
        // top and the error at the bottom. Tail-truncation loses the former,
        // head-truncation loses the latter — which is usually what was asked
        // about.
        let body = String(repeating: "x", count: 1000)
        let source = "START" + body + "ERROR: boom"
        let (text, truncated) = OutputClipper.clip(source, limit: 100)
        XCTAssertTrue(truncated)
        XCTAssertTrue(text.hasPrefix("START"))
        XCTAssertTrue(text.hasSuffix("ERROR: boom"))
        XCTAssertTrue(text.contains("characters omitted"))
    }

    func testClippedLengthIsBounded() {
        let source = String(repeating: "y", count: 10_000)
        let (text, _) = OutputClipper.clip(source, limit: 200)
        // The marker adds a bounded amount; the payload itself is at the limit.
        XCTAssertLessThan(text.count, 260)
    }

    func testZeroLimitIsHandled() {
        let (text, truncated) = OutputClipper.clip("abc", limit: 0)
        XCTAssertEqual(text, "")
        XCTAssertTrue(truncated)
    }
}
