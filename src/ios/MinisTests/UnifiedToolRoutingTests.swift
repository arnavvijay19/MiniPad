import XCTest

/// Coverage for turning a tool call into a plan for the right machine.
///
/// This is the layer where a bug runs the user's command on the wrong computer
/// or silently drops an argument, so the negative cases get as much attention
/// as the positive ones.
final class UnifiedToolRoutingTests: XCTestCase {

    private func plan(_ tool: String, _ args: [String: Any], remote: Bool = true) -> RemoteToolPlan {
        UnifiedToolRouting.plan(toolName: tool, args: args, remoteAvailable: remote)
    }

    // MARK: Local is the default

    func testNoTargetMeansLocal() {
        // The backwards-compatibility guarantee: every existing tool call, and
        // every model that has never heard of a second machine, runs locally.
        XCTAssertEqual(plan("shell_execute", ["command": "ls"]), .local)
        XCTAssertEqual(plan("file_read", ["path": "/var/minis/workspace/x.md"]), .local)
    }

    func testExplicitLocalTargetIsLocal() {
        XCTAssertEqual(plan("shell_execute", ["command": "ls", "target": "ipad"]), .local)
    }

    func testUnknownTargetIsLocal() {
        // Failing safe: an unintended local command is recoverable, an
        // unintended one on the user's PC may not be.
        XCTAssertEqual(plan("shell_execute", ["command": "ls", "target": "mars"]), .local)
    }

    // MARK: Routing to Windows

    func testExplicitWindowsTargetRoutesShell() {
        XCTAssertEqual(
            plan("shell_execute", ["command": "dir", "target": "windows"]),
            .shell(command: "dir", timeout: 900, workingDirectory: nil))
    }

    func testWindowsPathRoutesEvenWithoutTheTargetParameter() {
        // Small models copy a path out of an earlier result and drop the
        // parameter. Honouring the prefix is what the user meant and is what
        // keeps the two-machine model coherent.
        XCTAssertEqual(plan("file_read", ["path": "win:C:\\repo\\main.py"]),
                       .readFile(path: "C:\\repo\\main.py"))
        XCTAssertEqual(plan("file_read", ["path": "C:\\repo\\main.py"]),
                       .readFile(path: "C:\\repo\\main.py"))
    }

    func testTargetParameterWinsWhenThePathIsAmbiguous() {
        // `target: windows` with a bare path is a mistake worth reporting
        // rather than silently reading the iPad's copy.
        guard case .rejected = plan("file_read", ["path": "/etc/hosts", "target": "windows"]) else {
            return XCTFail("a POSIX path with target=windows must be rejected")
        }
    }

    func testWriteAndEditCarryEveryArgument() {
        XCTAssertEqual(
            plan("file_write", ["path": "win:C:\\a.txt", "content": "hi", "append": true]),
            .writeFile(path: "C:\\a.txt", content: "hi", append: true))
        XCTAssertEqual(
            plan("file_edit", ["path": "win:C:\\a.py", "old_string": "a",
                               "new_string": "b", "replace_all": true]),
            .editFile(path: "C:\\a.py", oldString: "a", newString: "b", replaceAll: true))
    }

    func testEmptyContentIsAValidWrite() {
        // Truncating a file is a legitimate operation and must not be rejected
        // as a missing argument.
        XCTAssertEqual(plan("file_write", ["path": "win:C:\\a.txt", "content": ""]),
                       .writeFile(path: "C:\\a.txt", content: "", append: false))
    }

    // MARK: Rejections

    func testRemoteCallWithNoEndpointIsRejectedWithAdvice() {
        guard case .rejected(let reason) = plan(
            "shell_execute", ["command": "dir", "target": "windows"], remote: false) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.contains("Settings"))
        XCTAssertTrue(reason.contains("omit `target`"))
    }

    func testNonWindowsPathForARemoteFileToolIsRejectedWithTheFix() {
        guard case .rejected(let reason) = plan(
            "file_read", ["path": "workspace/x.md", "target": "windows"]) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.contains("win:"), reason)
    }

    func testTraversalInARemotePathIsRejected() {
        guard case .rejected = plan("file_read", ["path": "win:C:\\repo\\..\\..\\Windows\\x"]) else {
            return XCTFail("traversal must be rejected")
        }
    }

    func testMissingRequiredArgumentsAreRejectedSpecifically() {
        for (tool, args) in [
            ("shell_execute", ["target": "windows"] as [String: Any]),
            ("shell_execute", ["target": "windows", "command": "   "]),
            ("file_write", ["path": "win:C:\\a.txt"]),
            ("file_edit", ["path": "win:C:\\a.txt", "new_string": "b"]),
            ("file_edit", ["path": "win:C:\\a.txt", "old_string": "", "new_string": "b"]),
        ] {
            guard case .rejected = plan(tool, args) else {
                return XCTFail("\(tool) with \(args) should be rejected")
            }
        }
    }

    func testIPadOnlyToolsAreRejectedRatherThanSilentlyRunLocally() {
        // Running browser_use locally when the model asked for Windows would
        // have it believe it screenshotted the PC.
        for tool in ["browser_use", "read_image", "memory_get", "memory_write"] {
            guard case .rejected(let reason) = plan(tool, ["target": "windows"]) else {
                return XCTFail("\(tool) should be rejected for a remote target")
            }
            XCTAssertTrue(reason.contains("only runs on the iPad"), reason)
        }
    }

    func testMismatchedWorkingDirectoryIsRejected() {
        guard case .rejected(let reason) = plan(
            "shell_execute", ["command": "dir", "target": "windows", "cwd": "/var/minis"]) else {
            return XCTFail("a POSIX cwd for a Windows command must be rejected")
        }
        XCTAssertTrue(reason.contains("Windows path"))
    }

    func testValidWindowsWorkingDirectoryIsPassedThrough() {
        XCTAssertEqual(
            plan("shell_execute", ["command": "dir", "target": "windows", "cwd": "win:C:\\repo"]),
            .shell(command: "dir", timeout: 900, workingDirectory: "C:\\repo"))
    }

    // MARK: Argument coercion

    func testTimeoutAcceptsWhateverTheModelEmits() {
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds(60), 60)
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds(60.5), 60.5)
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds("60"), 60)
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds(nil), 900)
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds("nonsense"), 900)
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds(0), 900, "zero is not a timeout")
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds(-5), 900)
    }

    func testTimeoutIsClamped() {
        // A model asking for a 24-hour timeout would otherwise pin a network
        // request open for the life of the app.
        XCTAssertEqual(UnifiedToolRouting.timeoutSeconds(86_400), 3600)
    }

    func testBooleanCoercion() {
        XCTAssertEqual(UnifiedToolRouting.boolValue(true), true)
        XCTAssertEqual(UnifiedToolRouting.boolValue("true"), true)
        XCTAssertEqual(UnifiedToolRouting.boolValue("no"), false)
        XCTAssertEqual(UnifiedToolRouting.boolValue(1), true)
        XCTAssertNil(UnifiedToolRouting.boolValue("maybe"))
        XCTAssertNil(UnifiedToolRouting.boolValue(nil))
    }

    func testUNCPathsRoute() {
        XCTAssertEqual(plan("file_read", ["path": "win:\\\\build01\\share\\out.log"]),
                       .readFile(path: "\\\\build01\\share\\out.log"))
    }
}
