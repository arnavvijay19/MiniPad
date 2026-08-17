import XCTest

/// Coverage for the unified execution vocabulary: target parsing, handles,
/// result rendering, and the scheme-qualified path model.
///
/// These are the types every two-machine tool call flows through, and their
/// failure modes are silent rather than loud — a mis-parsed target runs a
/// command on the wrong computer, a mis-parsed path writes to the wrong disk.
/// So the parsing rules are pinned exhaustively rather than sampled.
final class UnifiedExecutionTests: XCTestCase {

    // MARK: - ExecutionTarget.parse

    func testTargetDefaultsToIPadWhenAbsent() {
        // The whole backwards-compatibility story rests on this: every tool
        // call ever persisted, and every model that has never heard of a second
        // machine, must keep running locally.
        XCTAssertEqual(ExecutionTarget.parse(nil), .ipad)
        XCTAssertEqual(ExecutionTarget.parse(""), .ipad)
        XCTAssertEqual(ExecutionTarget.parse("   "), .ipad)
        XCTAssertEqual(ExecutionTarget.parse("null"), .ipad)
        XCTAssertEqual(ExecutionTarget.parse("default"), .ipad)
    }

    func testTargetAliasesForLocal() {
        for alias in ["ipad", "iPad", "LOCAL", "linux", "iSH", "alpine", "device", "sandbox", "ios"] {
            XCTAssertEqual(ExecutionTarget.parse(alias), .ipad, "alias '\(alias)'")
        }
    }

    func testTargetAliasesForWindows() {
        for alias in ["windows", "Windows", "WIN", "pc", "desktop", "remote", "windows-pc", "windows_pc"] {
            XCTAssertEqual(ExecutionTarget.parse(alias), .windows, "alias '\(alias)'")
        }
    }

    func testTargetSubstringFallback() {
        // Small models editorialise: "windows (my desktop)" is a real emission.
        XCTAssertEqual(ExecutionTarget.parse("windows (my desktop)"), .windows)
        XCTAssertEqual(ExecutionTarget.parse("the desktop machine"), .windows)
    }

    func testUnknownTargetFailsSafeToLocal() {
        // An unrecognised target must never escalate to the remote machine:
        // running an unintended command locally is recoverable, running it on
        // the user's PC may not be.
        XCTAssertEqual(ExecutionTarget.parse("mars"), .ipad)
        XCTAssertEqual(ExecutionTarget.parse("server"), .ipad)
    }

    // MARK: - ExecutionHandle

    func testHandleTokenRoundTrip() {
        let handle = ExecutionHandle(target: .windows, id: "41208")
        XCTAssertEqual(handle.token, "windows:41208")
        XCTAssertEqual(ExecutionHandle.parse(token: "windows:41208"), handle)
    }

    func testHandleParseRejectsMalformed() {
        // A hallucinated handle must fail rather than resolve to some default
        // target — otherwise the model's invented pid gets sent to a real
        // machine.
        XCTAssertNil(ExecutionHandle.parse(token: "41208"))
        XCTAssertNil(ExecutionHandle.parse(token: "windows:"))
        XCTAssertNil(ExecutionHandle.parse(token: "mars:41208"))
        XCTAssertNil(ExecutionHandle.parse(token: ""))
    }

    func testHandleIDMayContainColons() {
        // Session ids from some endpoints are UUID-ish with separators; only
        // the FIRST colon delimits the target.
        let handle = ExecutionHandle.parse(token: "windows:sess:ab:12")
        XCTAssertEqual(handle?.id, "sess:ab:12")
        XCTAssertEqual(handle?.target, .windows)
    }

    // MARK: - ExecutionState

    func testStateSuccessOnlyForZeroExit() {
        XCTAssertTrue(ExecutionState.exited(code: 0).isSuccess)
        XCTAssertFalse(ExecutionState.exited(code: 1).isSuccess)
        XCTAssertFalse(ExecutionState.timedOut.isSuccess)
        XCTAssertFalse(ExecutionState.cancelled.isSuccess)
        XCTAssertFalse(ExecutionState.failed(message: "x").isSuccess)
        XCTAssertFalse(ExecutionState.running.isSuccess)
    }

    func testRunningIsNotTerminal() {
        XCTAssertFalse(ExecutionState.running.isTerminal)
        XCTAssertTrue(ExecutionState.exited(code: 0).isTerminal)
        XCTAssertTrue(ExecutionState.timedOut.isTerminal)
    }

    // MARK: - Result rendering

    func testLocalResultHasNoProvenancePrefix() {
        // The common case must cost zero extra tokens and must not change how
        // existing local results read.
        let result = ExecutionResult(target: .ipad, state: .exited(code: 0), output: "hello")
        XCTAssertEqual(result.modelFacingText(), "hello")
    }

    func testRemoteResultCarriesProvenance() {
        // Losing track of which machine a result came from is the defining
        // failure of a two-machine agent, so remote results always say so.
        let result = ExecutionResult(target: .windows, state: .exited(code: 0), output: "hello")
        let text = result.modelFacingText(hostLabel: "Desktop")
        XCTAssertTrue(text.hasPrefix("[ran on Windows (Desktop)]"), text)
        XCTAssertTrue(text.contains("hello"))
    }

    func testNonZeroExitIsReportedToTheModel() {
        let result = ExecutionResult(target: .ipad, state: .exited(code: 2), output: "boom")
        XCTAssertTrue(result.modelFacingText().contains("Exit code: 2"))
    }

    func testRunningResultExposesHandleSoTheModelCanPoll() {
        let handle = ExecutionHandle(target: .windows, id: "77")
        let result = ExecutionResult(target: .windows, handle: handle, state: .running, output: "")
        let text = result.modelFacingText()
        XCTAssertTrue(text.contains("handle=windows:77"), text)
    }

    func testEmptyOutputIsExplicitNotBlank() {
        // A blank tool result reads to a model as "the tool is broken"; "(no
        // output)" reads as "it ran and printed nothing", which is the truth.
        let result = ExecutionResult(target: .ipad, state: .exited(code: 0), output: "")
        XCTAssertEqual(result.modelFacingText(), "(no output)")
    }

    func testStderrIsUsedWhenStdoutIsEmpty() {
        let result = ExecutionResult(target: .ipad, state: .exited(code: 1), output: "", stderr: "not found")
        XCTAssertTrue(result.modelFacingText().contains("not found"))
    }

    // MARK: - UnifiedPath parsing

    func testBarePathIsLocalAndRoundTripsUnchanged() {
        // Backwards compatibility: an existing tool call passing a plain Linux
        // path must be untouched, all the way through to the string form.
        let p = UnifiedPath.parse("/var/minis/workspace/report.md")
        XCTAssertEqual(p.scheme, .ipad)
        XCTAssertEqual(p.path, "/var/minis/workspace/report.md")
        XCTAssertEqual(p.description, "/var/minis/workspace/report.md")
        XCTAssertFalse(p.schemeWasExplicit)
    }

    func testExplicitSchemesParse() {
        XCTAssertEqual(UnifiedPath.parse("ipad:/root/x").scheme, .ipad)
        XCTAssertEqual(UnifiedPath.parse("win:C:\\Users\\me").scheme, .win)
        XCTAssertEqual(UnifiedPath.parse("files:/Notes/todo.md").scheme, .files)
    }

    func testDriveLetterIsNotMistakenForAScheme() {
        // "C:" looks exactly like a scheme prefix. Getting this wrong would
        // parse every Windows path as an unknown scheme and silently treat it
        // as a local path.
        let p = UnifiedPath.parse("C:\\Users\\me\\repo\\main.py")
        XCTAssertEqual(p.scheme, .win)
        XCTAssertEqual(p.path, "C:\\Users\\me\\repo\\main.py")
    }

    func testBareUNCPathIsWindows() {
        let p = UnifiedPath.parse("\\\\build01\\share\\out.log")
        XCTAssertEqual(p.scheme, .win)
        XCTAssertEqual(p.path, "\\\\build01\\share\\out.log")
    }

    func testMinisURLSchemeIsPassedThroughUntouched() {
        // The app's existing scheme has its own semantics (MinisURLPathDecoding);
        // this type must not rewrite it.
        let raw = "minis://workspace/index.html"
        let p = UnifiedPath.parse(raw)
        XCTAssertEqual(p.scheme, .minis)
        XCTAssertEqual(p.description, raw)
    }

    func testSeparatorsAreNormalisedPerMachine() {
        // A model that types forward slashes for Windows shouldn't produce a
        // path PowerShell has to guess at.
        XCTAssertEqual(UnifiedPath.parse("win:C:/Users/me/x.txt").path, "C:\\Users\\me\\x.txt")
        XCTAssertEqual(UnifiedPath.parse("ipad:\\var\\log").path, "/var/log")
    }

    func testUNCNormalisationKeepsTheDoubleLeadingSeparator() {
        XCTAssertEqual(UnifiedPath.parse("win://build01/share/x").path, "\\\\build01\\share\\x")
    }

    func testQualifiedFormAlwaysNamesTheMachine() {
        XCTAssertEqual(UnifiedPath.parse("/root/x").qualified, "ipad:/root/x")
        XCTAssertEqual(UnifiedPath.parse("C:\\x").qualified, "win:C:\\x")
    }

    // MARK: - UnifiedPath validation

    func testRelativePathsAreRejected() {
        XCTAssertEqual(UnifiedPath.parse("relative/path.txt").validate(), .notAbsolute(.ipad))
    }

    func testWindowsPathWithoutRootIsRejected() {
        XCTAssertEqual(UnifiedPath.parse("win:Users\\me").validate(), .windowsPathMissingRoot)
    }

    func testTraversalIsRejectedNotResolved() {
        // Resolving `..` here would be wrong — this type can't know whether an
        // intermediate segment is a symlink, and on the Windows side the shell
        // resolves it anyway. Rejecting stops `..` being used to climb out of a
        // directory the user scoped a permission to.
        XCTAssertEqual(UnifiedPath.parse("/var/minis/../../etc/passwd").validate(), .traversal)
        XCTAssertEqual(UnifiedPath.parse("win:C:\\repo\\..\\..\\Windows").validate(), .traversal)
    }

    func testTraversalCheckDoesNotFalsePositiveOnDotDotInsideAName() {
        // "..config" and "a..b" contain "..", but neither is a traversal
        // segment; rejecting them would break legitimate filenames.
        XCTAssertNil(UnifiedPath.parse("/root/..config").validate())
        XCTAssertNil(UnifiedPath.parse("/root/a..b/file.txt").validate())
    }

    func testNulByteIsRejected() {
        XCTAssertEqual(UnifiedPath.parse("/root/a\0b").validate(), .nulByte)
    }

    func testValidPathsPass() {
        XCTAssertNil(UnifiedPath.parse("/var/minis/workspace/x.md").validate())
        XCTAssertNil(UnifiedPath.parse("win:C:\\Users\\me\\x.py").validate())
        XCTAssertNil(UnifiedPath.parse("win:\\\\host\\share\\x").validate())
    }

    // MARK: - Path components

    func testComponentsUseTheOwningMachinesSeparator() {
        XCTAssertEqual(UnifiedPath.parse("win:C:\\a\\b\\main.py").lastComponent, "main.py")
        XCTAssertEqual(UnifiedPath.parse("/a/b/main.py").lastComponent, "main.py")
        XCTAssertEqual(UnifiedPath.parse("win:C:\\a\\b\\main.PY").pathExtension, "py")
        XCTAssertEqual(UnifiedPath.parse("/a/b/noext").pathExtension, "")
        XCTAssertEqual(UnifiedPath.parse("/a/.hidden").pathExtension, "",
                       "a leading dot is not an extension")
    }

    func testAppendingUsesTheRightSeparatorAndDoesNotDoubleIt() {
        XCTAssertEqual(UnifiedPath.parse("win:C:\\repo\\").appending("main.py").path, "C:\\repo\\main.py")
        XCTAssertEqual(UnifiedPath.parse("/repo/").appending("/main.py").path, "/repo/main.py")
    }

    // MARK: - Provenance

    func testProvenanceNamesTheMachine() {
        XCTAssertEqual(UnifiedPath.parse("/x").provenance(), "iPad · Linux sandbox")
        XCTAssertEqual(UnifiedPath.parse("win:C:\\x").provenance(windowsHost: "Desktop"), "Windows · Desktop")
        XCTAssertEqual(UnifiedPath.parse("files:/x").provenance(), "iPad · Files (user-authorized)")
    }

    // MARK: - Cross-target copy

    func testCopyDetectsCrossMachineTransfer() {
        let copy = CrossTargetCopy(
            source: UnifiedPath.parse("/var/minis/workspace/a.txt"),
            destination: UnifiedPath.parse("win:C:\\tmp\\a.txt")
        )
        XCTAssertTrue(copy.crossesMachines)
        XCTAssertNil(copy.validate())
        XCTAssertTrue(copy.summary.contains("⇢"), "cross-machine copies are visually distinct")
    }

    func testSameMachineCopyIsNotACrossMachineTransfer() {
        let copy = CrossTargetCopy(
            source: UnifiedPath.parse("/a.txt"),
            destination: UnifiedPath.parse("/b.txt")
        )
        XCTAssertFalse(copy.crossesMachines)
        XCTAssertTrue(copy.summary.contains("→"))
    }

    func testCopyValidationRejectsBadEndpointsAndSelfCopy() {
        let badSource = CrossTargetCopy(
            source: UnifiedPath.parse("relative.txt"),
            destination: UnifiedPath.parse("win:C:\\x")
        )
        XCTAssertEqual(badSource.validate(), .invalidSource(.notAbsolute(.ipad)))

        let badDest = CrossTargetCopy(
            source: UnifiedPath.parse("/x"),
            destination: UnifiedPath.parse("win:notabsolute")
        )
        XCTAssertEqual(badDest.validate(), .invalidDestination(.windowsPathMissingRoot))

        let same = CrossTargetCopy(
            source: UnifiedPath.parse("/x"),
            destination: UnifiedPath.parse("/x")
        )
        XCTAssertEqual(same.validate(), .sameLocation)
    }

    // MARK: - Prompt fragment

    func testNamespaceFragmentNamesBothMachinesAndTheNoSyncRule() {
        let fragment = UnifiedWorkspaceNamespace.promptFragment(windowsHost: "Desktop")
        XCTAssertTrue(fragment.contains("win:"))
        XCTAssertTrue(fragment.contains("Desktop"))
        XCTAssertTrue(fragment.lowercased().contains("do not sync"),
                      "the model must be told files don't sync, or it will assume they do")
    }
}
