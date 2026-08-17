//
//  RemoteCommandRisk.swift
//  MinisApp
//
//  Which remote commands deserve a confirmation prompt.
//
//  The Windows target is arbitrary code execution on the user's PC, initiated
//  by a model that may be 4B parameters. `OffloadPermissionManager` already
//  owns the app's permission vocabulary for local offload commands; this
//  classifies the remote side so it can reuse that machinery instead of
//  inventing a second prompt style.
//
//  DESIGN CONSTRAINT: this must not become a security boundary.
//
//  A command classifier cannot be one. `cmd /c "del /s C:\"` and a base64
//  payload piped to PowerShell both execute the same thing while matching
//  nothing here, and a determined bypass is a shell quoting trick away. What it
//  IS is a guardrail against the realistic failure — a model that misreads the
//  task and reaches for `Remove-Item -Recurse` on the wrong directory — which
//  is exactly what a confirmation prompt catches.
//
//  So: match generously, never claim completeness, and say plainly in the
//  prompt what is about to run.
//
//  Pure Foundation, unit-tested.
//

import Foundation

/// How consequential a remote operation is.
enum RemoteRisk: Equatable, Sendable, Comparable {
    /// Reads, listings, builds, tests. Runs without asking.
    case ordinary
    /// Writes or deletes on the PC, or moves bytes between machines.
    case destructive(reason: String)

    private var rank: Int {
        switch self {
        case .ordinary: return 0
        case .destructive: return 1
        }
    }

    static func < (a: RemoteRisk, b: RemoteRisk) -> Bool { a.rank < b.rank }

    var needsConfirmation: Bool { self != .ordinary }
}

enum RemoteCommandRisk {

    /// Command fragments that delete, overwrite or reconfigure.
    ///
    /// Lowercased substrings rather than a parser: a parser that is 90% right
    /// invites trust it hasn't earned, whereas substrings are obviously
    /// heuristic and behave predictably. Each entry pairs with the phrase shown
    /// to the user, so the prompt says *what* was matched.
    static let destructivePatterns: [(fragment: String, reason: String)] = [
        ("remove-item", "deletes files"),
        ("rm -rf", "deletes files recursively"),
        ("rm -r", "deletes a directory"),
        ("del /", "deletes files"),
        ("erase ", "deletes files"),
        ("rmdir", "removes a directory"),
        ("format ", "formats a volume"),
        ("mkfs", "formats a filesystem"),
        ("diskpart", "repartitions a disk"),
        ("clear-disk", "erases a disk"),
        ("git reset --hard", "discards uncommitted work"),
        ("git clean -", "deletes untracked files"),
        ("git push --force", "rewrites remote history"),
        ("git push -f", "rewrites remote history"),
        ("drop database", "drops a database"),
        ("drop table", "drops a table"),
        ("truncate table", "empties a table"),
        ("shutdown", "shuts the machine down"),
        ("restart-computer", "restarts the machine"),
        ("stop-computer", "shuts the machine down"),
        ("set-executionpolicy", "changes PowerShell's security policy"),
        ("reg delete", "deletes registry keys"),
        ("takeown", "changes file ownership"),
        ("icacls", "changes file permissions"),
        ("net user", "changes user accounts"),
        ("uninstall", "uninstalls software"),
    ]

    /// Classify a remote shell command.
    static func classify(command: String) -> RemoteRisk {
        let lowered = command.lowercased()
        for (fragment, reason) in destructivePatterns where lowered.contains(fragment) {
            return .destructive(reason: reason)
        }
        // Output redirection overwrites. `>>` appends and is not flagged; the
        // ordering matters, because `>>` contains `>`.
        if lowered.contains(">>") {
            return .ordinary
        }
        if lowered.contains(" > ") || lowered.contains("out-file") || lowered.contains("set-content") {
            return .destructive(reason: "overwrites a file")
        }
        return .ordinary
    }

    /// Classify a planned remote tool operation.
    ///
    /// Writes and edits are destructive by definition — they change a file on a
    /// machine the user isn't looking at. Reads never are.
    static func classify(plan: RemoteToolPlan) -> RemoteRisk {
        switch plan {
        case .shell(let command, _, _):
            return classify(command: command)
        case .writeFile(let path, _, _):
            return .destructive(reason: "overwrites win:\(path)")
        case .editFile(let path, _, _, _):
            return .destructive(reason: "edits win:\(path)")
        case .readFile, .local, .rejected:
            return .ordinary
        }
    }

    /// The sentence shown in the confirmation prompt.
    ///
    /// Names the machine first. The single most damaging confirmation-prompt
    /// failure is a user approving something believing it applies to the iPad.
    static func confirmationMessage(
        risk: RemoteRisk,
        hostLabel: String,
        detail: String
    ) -> String? {
        guard case .destructive(let reason) = risk else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
        return "On \(hostLabel) (your PC), the agent wants to run something that \(reason):\n\n\(shown)"
    }
}
