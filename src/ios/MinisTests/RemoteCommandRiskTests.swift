import XCTest

/// Coverage for which remote operations get a confirmation prompt.
///
/// The classifier is explicitly NOT a security boundary — see the file header
/// on RemoteCommandRisk. These tests pin it as what it is: a guardrail against
/// a model that misread the task and reached for a destructive command. So they
/// check that the realistic destructive shapes are caught, that ordinary work
/// isn't interrupted, and that the prompt text can't be misread as applying to
/// the iPad.
final class RemoteCommandRiskTests: XCTestCase {

    // MARK: Destructive commands

    func testDeletionCommandsAreFlagged() {
        for command in [
            "Remove-Item -Recurse -Force C:\\build",
            "rm -rf /c/repo/node_modules",
            "del /s /q C:\\temp",
            "rmdir /s C:\\old",
            "Erase C:\\file.txt",
        ] {
            XCTAssertTrue(RemoteCommandRisk.classify(command: command).needsConfirmation,
                          "not flagged: \(command)")
        }
    }

    func testHistoryRewritingGitCommandsAreFlagged() {
        // The realistic destructive case for a dev machine: a model "cleaning
        // up" a repo and discarding hours of uncommitted work.
        for command in ["git reset --hard HEAD~3", "git clean -fdx",
                        "git push --force origin main", "git push -f"] {
            XCTAssertTrue(RemoteCommandRisk.classify(command: command).needsConfirmation,
                          "not flagged: \(command)")
        }
    }

    func testSystemLevelCommandsAreFlagged() {
        for command in ["shutdown /s /t 0", "Restart-Computer", "diskpart",
                        "Set-ExecutionPolicy Unrestricted", "reg delete HKLM\\Software\\X",
                        "net user admin /add"] {
            XCTAssertTrue(RemoteCommandRisk.classify(command: command).needsConfirmation,
                          "not flagged: \(command)")
        }
    }

    func testDatabaseDestructionIsFlagged() {
        XCTAssertTrue(RemoteCommandRisk.classify(command: "psql -c 'DROP TABLE users'").needsConfirmation)
        XCTAssertTrue(RemoteCommandRisk.classify(command: "DROP DATABASE prod").needsConfirmation)
    }

    func testCaseInsensitive() {
        XCTAssertTrue(RemoteCommandRisk.classify(command: "REMOVE-ITEM C:\\x").needsConfirmation)
        XCTAssertTrue(RemoteCommandRisk.classify(command: "Git Reset --Hard").needsConfirmation)
    }

    // MARK: Ordinary work is not interrupted

    func testOrdinaryDevelopmentCommandsRunWithoutPrompting() {
        // If these prompted, the feature would be unusable — a build or a test
        // run is the whole point of the Windows target.
        for command in [
            "npm test",
            "git status",
            "git log --oneline -20",
            "dotnet build",
            "python -m pytest tests/",
            "Get-ChildItem C:\\repo",
            "cat README.md",
            "git diff HEAD",
        ] {
            XCTAssertEqual(RemoteCommandRisk.classify(command: command), .ordinary,
                           "wrongly flagged: \(command)")
        }
    }

    func testAppendRedirectIsNotFlaggedButOverwriteIs() {
        // `>>` contains `>`, so ordering inside the classifier matters. Getting
        // it wrong prompts on every log append.
        XCTAssertEqual(RemoteCommandRisk.classify(command: "echo hi >> build.log"), .ordinary)
        XCTAssertTrue(RemoteCommandRisk.classify(command: "echo hi > build.log").needsConfirmation)
        XCTAssertTrue(RemoteCommandRisk.classify(command: "Get-Date | Out-File log.txt").needsConfirmation)
    }

    // MARK: Plans

    func testWritesAndEditsAreAlwaysDestructive() {
        // They change a file on a machine the user isn't looking at.
        XCTAssertTrue(RemoteCommandRisk.classify(
            plan: .writeFile(path: "C:\\x.txt", content: "hi", append: false)).needsConfirmation)
        XCTAssertTrue(RemoteCommandRisk.classify(
            plan: .editFile(path: "C:\\x.py", oldString: "a", newString: "b",
                            replaceAll: false)).needsConfirmation)
    }

    func testReadsAreNever() {
        XCTAssertEqual(RemoteCommandRisk.classify(plan: .readFile(path: "C:\\x.txt")), .ordinary)
    }

    func testLocalPlansAreNeverFlagged() {
        // Local execution has its own permission system; double-prompting would
        // be a regression for every existing user.
        XCTAssertEqual(RemoteCommandRisk.classify(plan: .local), .ordinary)
        XCTAssertEqual(RemoteCommandRisk.classify(plan: .rejected(reason: "x")), .ordinary)
    }

    // MARK: The prompt

    func testPromptNamesTheMachineFirst() {
        // The most damaging confirmation failure is a user approving something
        // while believing it applies to the iPad.
        let message = RemoteCommandRisk.confirmationMessage(
            risk: .destructive(reason: "deletes files"),
            hostLabel: "Desktop",
            detail: "Remove-Item -Recurse C:\\build"
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.hasPrefix("On Desktop (your PC)"), message!)
        XCTAssertTrue(message!.contains("deletes files"))
        XCTAssertTrue(message!.contains("Remove-Item -Recurse C:\\build"),
                      "the user must see the actual command")
    }

    func testPromptTruncatesAVeryLongCommand() {
        let long = String(repeating: "x", count: 5000)
        let message = RemoteCommandRisk.confirmationMessage(
            risk: .destructive(reason: "deletes files"), hostLabel: "PC", detail: long)!
        XCTAssertLessThan(message.count, 500)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testNoPromptForOrdinaryRisk() {
        XCTAssertNil(RemoteCommandRisk.confirmationMessage(
            risk: .ordinary, hostLabel: "PC", detail: "npm test"))
    }
}

// MARK: - Local model registration

/// Coverage for how a local model is recognised and routed.
///
/// The `local/` prefix is the single source of truth: get this wrong in one
/// direction and a local model silently goes to a cloud provider; wrong in the
/// other and a remote model is handed to the on-device runtime.
final class LocalModelRegistrationTests: XCTestCase {

    func testAppModelIDRoundTrips() {
        let entry = LocalModelEntry(repoID: "mlx-community/Qwen3.5-4B-4bit", displayName: "Q")
        XCTAssertEqual(entry.appModelID, "local/mlx-community/Qwen3.5-4B-4bit")
        XCTAssertEqual(LocalModelEntry.repoID(fromAppModelID: entry.appModelID),
                       "mlx-community/Qwen3.5-4B-4bit")
    }

    func testRemoteModelIDsAreNotMistakenForLocal() {
        // A remote model id containing a slash must never route on-device.
        for id in ["claude-opus-5", "gpt-5.5", "anthropic/claude-opus-5",
                   "openrouter/auto", "", "local", "locally/x"] {
            XCTAssertNil(LocalModelEntry.repoID(fromAppModelID: id), "wrongly local: \(id)")
        }
    }

    func testEmptyRepoAfterPrefixIsRejected() {
        XCTAssertNil(LocalModelEntry.repoID(fromAppModelID: "local/"))
    }

    func testToolSurfaceModeFollowsLocality() {
        // Local models get the lean surface (measured 68% fewer tool tokens);
        // remote models must keep the full surface so upstream behaviour is
        // byte-identical.
        XCTAssertEqual(
            LocalAgentProviderFactory.toolSurfaceMode(forModelID: "local/mlx-community/Qwen3.5-4B-4bit"),
            .lean)
        XCTAssertEqual(LocalAgentProviderFactory.toolSurfaceMode(forModelID: "claude-opus-5"), .full)
    }
}
