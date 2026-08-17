//
//  ExecutionTarget.swift
//  MinisApp
//
//  The unified execution abstraction: one agent, several machines.
//
//  Minis already has a first-class local execution environment (the in-app
//  Alpine/iSH sandbox, driven by ISHExecutionCoordinator). This file adds the
//  *vocabulary* that lets the same agent loop address a second machine — the
//  user's Windows PC, reached through their own Desktop Commander MCP endpoint
//  — without the model having to learn a second, parallel tool surface.
//
//  Design constraints this file is written against:
//
//  1. NO tool-surface growth. The agent keeps `shell_execute` / `file_read` /
//     `file_write` / `file_edit`. Targeting is expressed as ONE optional
//     enum-valued parameter (`target`) on the tools that already exist, not as
//     five new Windows-specific tools. A 4B local model pays ~30 tokens for
//     the whole capability instead of ~1200 for a parallel tool family.
//     See ToolContextBudget for the measured numbers.
//
//  2. Absent means local. Every existing call site, every persisted tool call
//     in chat history, and every model that has never heard of Windows keeps
//     working unchanged: a missing/empty `target` resolves to `.ipad`.
//
//  3. Same semantics on both sides. A command has a start, streamed output, an
//     optional interactive stdin channel, a terminal state and a cancel path,
//     whether it runs in iSH or in PowerShell. Callers branch on the target
//     only to pick a backend, never to reinterpret the result.
//
//  This file is deliberately pure Foundation with no app dependencies so it can
//  be unit-tested off-device (see MinisTests/UnifiedExecutionTests.swift).
//

import Foundation

// MARK: - Target

/// A machine the agent can run work on.
///
/// Deliberately a small closed enum rather than an open registry: the model has
/// to be able to enumerate the legal values in a tool schema, and every added
/// case costs tokens in every request for the rest of the app's life. New
/// *hosts* (a second PC, a Mac) are additional `ExecutionEndpoint`s under
/// `.windows`-style remote kinds, not additional enum cases.
enum ExecutionTarget: String, Codable, Sendable, CaseIterable, Hashable {
    /// The in-app Alpine Linux sandbox running on this iPad (iSH).
    case ipad
    /// A remote Windows host reached over the user's configured MCP endpoint.
    case windows

    /// Value used in tool schemas and persisted tool-call arguments.
    var wireValue: String { rawValue }

    /// Parse a model-supplied target. Unknown/absent/blank → `.ipad`.
    ///
    /// Small models are sloppy about this field: they emit "local", "linux",
    /// "iSH", "pc", "desktop", capitalised variants, and sometimes the literal
    /// string "null". Recovering here is much cheaper than a rejected tool call
    /// and a wasted turn, and every alias below maps to exactly one target with
    /// no ambiguity.
    static func parse(_ raw: String?) -> ExecutionTarget {
        guard let raw else { return .ipad }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "", "null", "none", "nil", "default":
            return .ipad
        case "ipad", "local", "linux", "ish", "alpine", "device", "phone", "ios", "sandbox":
            return .ipad
        case "windows", "win", "pc", "desktop", "remote", "windows_pc", "windows-pc":
            return .windows
        default:
            // Substring fallback for things like "windows (my desktop)".
            if key.contains("win") || key.contains("desktop") { return .windows }
            return .ipad
        }
    }

    /// Short human label for UI badges and provenance lines.
    var displayName: String {
        switch self {
        case .ipad: return "iPad"
        case .windows: return "Windows"
        }
    }

    /// True when reaching this target requires a configured remote endpoint.
    var isRemote: Bool {
        switch self {
        case .ipad: return false
        case .windows: return true
        }
    }

    /// Native path separator for the target's filesystem. Used when joining
    /// paths for a target rather than for the host we happen to be running on.
    var pathSeparator: Character {
        switch self {
        case .ipad: return "/"
        case .windows: return "\\"
        }
    }
}

// MARK: - Process lifecycle

/// Identifies one running (or finished) command on a specific target.
///
/// The `id` is opaque and target-defined: a PID string for iSH, the Desktop
/// Commander process id for Windows. Callers must not parse it.
struct ExecutionHandle: Hashable, Sendable, Codable {
    let target: ExecutionTarget
    let id: String

    init(target: ExecutionTarget, id: String) {
        self.target = target
        self.id = id
    }

    /// Stable string form used in tool results so a later turn can refer back
    /// to a process the model started earlier ("windows:41208").
    var token: String { "\(target.rawValue):\(id)" }

    /// Inverse of `token`. Returns nil for anything that isn't a well-formed
    /// token, so a hallucinated handle fails loudly instead of silently
    /// addressing the wrong machine.
    static func parse(token: String) -> ExecutionHandle? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty,
              let target = ExecutionTarget(rawValue: String(parts[0]))
        else { return nil }
        return ExecutionHandle(target: target, id: String(parts[1]))
    }
}

/// Terminal or in-flight state of a command, identical in shape for both
/// targets so the agent loop and the UI never special-case a machine.
enum ExecutionState: Sendable, Equatable {
    /// Still running; no exit code yet.
    case running
    /// Finished normally. `code` is the process exit status (0 = success).
    case exited(code: Int)
    /// Wall-clock budget elapsed before the process finished.
    case timedOut
    /// Cancelled by the user (stop button) or by task cancellation.
    case cancelled
    /// Could not run at all: transport failure, host unreachable, permission
    /// denied. `message` is user- and model-facing.
    case failed(message: String)

    var isTerminal: Bool {
        if case .running = self { return false }
        return true
    }

    /// Exit code if the process actually ran to completion, else nil.
    var exitCode: Int? {
        if case .exited(let code) = self { return code }
        return nil
    }

    /// True only for a clean zero exit. `timedOut` / `cancelled` / `failed` and
    /// any nonzero exit are all failures for the purposes of tool results.
    var isSuccess: Bool { exitCode == 0 }
}

/// One completed execution, whichever machine it ran on.
struct ExecutionResult: Sendable {
    let target: ExecutionTarget
    let handle: ExecutionHandle?
    let state: ExecutionState
    /// Combined output as shown to the model. Streams are already interleaved
    /// in emission order by the executor; `stderrOnly` carries the error stream
    /// separately when the backend can distinguish it.
    let output: String
    /// Error stream, when the backend separates it. Empty otherwise.
    let stderr: String
    /// True when `output` was clipped to fit the result budget.
    let truncated: Bool
    /// Wall-clock duration of the run.
    let duration: TimeInterval

    init(
        target: ExecutionTarget,
        handle: ExecutionHandle? = nil,
        state: ExecutionState,
        output: String,
        stderr: String = "",
        truncated: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.target = target
        self.handle = handle
        self.state = state
        self.output = output
        self.stderr = stderr
        self.truncated = truncated
        self.duration = duration
    }

    /// Render the result the way the model sees it.
    ///
    /// The provenance prefix exists because the single most damaging failure
    /// mode of a two-machine agent is the model losing track of which machine a
    /// file or process lives on and then "fixing" the wrong one. One short line
    /// per remote result is cheap insurance; local results stay unprefixed so
    /// the overwhelmingly common case costs zero extra tokens and existing
    /// prompt behaviour is unchanged.
    func modelFacingText(hostLabel: String? = nil) -> String {
        var parts: [String] = []
        if target.isRemote {
            let host = hostLabel.map { " (\($0))" } ?? ""
            parts.append("[ran on \(target.displayName)\(host)]")
        }
        switch state {
        case .running:
            if let handle {
                parts.append("Process started, still running. handle=\(handle.token)")
            } else {
                parts.append("Process started, still running.")
            }
        case .exited(let code) where code != 0:
            parts.append("Exit code: \(code)")
        case .exited:
            break
        case .timedOut:
            parts.append("Timed out before the command finished.")
        case .cancelled:
            parts.append("Cancelled.")
        case .failed(let message):
            parts.append("Error: \(message)")
        }
        let body = output.isEmpty ? (stderr.isEmpty ? "(no output)" : stderr) : output
        parts.append(body)
        if truncated {
            parts.append("[output truncated]")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Request

/// A command to run on some target. One shape for both machines.
struct ExecutionRequest: Sendable {
    let target: ExecutionTarget
    /// The command line. Interpreted by the target's default shell:
    /// `/bin/sh -c` on iPad, the endpoint's configured shell (typically
    /// PowerShell) on Windows.
    let command: String
    /// Working directory in the target's own path syntax, or nil for the
    /// target's default.
    let workingDirectory: String?
    /// Wall-clock budget in seconds.
    let timeout: TimeInterval
    /// When true the executor returns as soon as the process is started,
    /// handing back a handle the model can poll or write to. Used for REPLs,
    /// dev servers and long builds.
    let interactive: Bool

    init(
        target: ExecutionTarget,
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 900,
        interactive: Bool = false
    ) {
        self.target = target
        self.command = command
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.interactive = interactive
    }
}

// MARK: - Executor protocol

/// What every execution backend must provide. Intentionally small: anything a
/// backend can't do natively is emulated in the adapter, so callers never need
/// capability checks scattered through the agent loop.
protocol UnifiedExecutor: Sendable {
    var target: ExecutionTarget { get }

    /// Run a command. For `interactive` requests this returns once the process
    /// is up, with `state == .running`; otherwise it returns on completion.
    /// `onOutput` is called with incremental output as it arrives.
    func run(
        _ request: ExecutionRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ExecutionResult

    /// Read whatever output a still-running process has produced since the last
    /// read. Returns immediately with what is buffered.
    func readOutput(_ handle: ExecutionHandle, timeout: TimeInterval) async throws -> ExecutionResult

    /// Write to a running process's stdin and read the reply.
    func interact(
        _ handle: ExecutionHandle,
        input: String,
        timeout: TimeInterval
    ) async throws -> ExecutionResult

    /// Terminate a running process. Idempotent: cancelling a finished process
    /// is not an error.
    func cancel(_ handle: ExecutionHandle) async throws
}

// MARK: - Availability

/// Why a target can't be used right now, in words that are worth showing to
/// both the user and the model.
enum ExecutionTargetUnavailable: Error, LocalizedError, Equatable {
    case notConfigured(ExecutionTarget)
    case kernelNotBooted
    case unreachable(ExecutionTarget, detail: String)
    case permissionDenied(ExecutionTarget, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let t):
            return "No \(t.displayName) endpoint is configured. Add one in Settings → Integrations → Remote Computer."
        case .kernelNotBooted:
            return "The Linux sandbox isn't running yet. Open a chat or the terminal once, then retry."
        case .unreachable(let t, let detail):
            return "Can't reach \(t.displayName): \(detail)"
        case .permissionDenied(let t, let detail):
            return "\(t.displayName) refused the request: \(detail)"
        }
    }
}
