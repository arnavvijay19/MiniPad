//
//  UnifiedToolRouting.swift
//  MinisApp
//
//  Turning a tool call into a plan for whichever machine it named.
//
//  Split into a pure planner (this file) and a thin executor seam
//  (UnifiedToolRouter) so the part that decides *what a tool call means* — the
//  part where a bug sends the user's command to the wrong computer or drops an
//  argument — is unit-tested, while the part that performs it is a few lines of
//  delegation.
//
//  The agent loop's existing tool cases stay exactly as they are for local
//  calls. The integration is one early return per case: if the planner says
//  this call is remote, the remote result is used; otherwise the original code
//  runs untouched. That keeps the diff against upstream additive.
//

import Foundation

/// What a tool call resolves to.
enum RemoteToolPlan: Equatable, Sendable {
    /// Runs locally — the caller proceeds with the existing implementation.
    case local

    case shell(command: String, timeout: TimeInterval, workingDirectory: String?)
    case readFile(path: String)
    case writeFile(path: String, content: String, append: Bool)
    case editFile(path: String, oldString: String, newString: String, replaceAll: Bool)

    /// The call named a remote target but can't be carried out, with a reason
    /// worth showing the model so it can correct itself rather than retry.
    case rejected(reason: String)
}

enum UnifiedToolRouting {

    /// Decide what a tool call means.
    ///
    /// - Parameters:
    ///   - toolName: the canonical tool name from the agent loop.
    ///   - args: decoded tool arguments.
    ///   - remoteAvailable: whether a remote endpoint is configured and enabled.
    static func plan(
        toolName: String,
        args: [String: Any],
        remoteAvailable: Bool
    ) -> RemoteToolPlan {
        // A path can carry its own target: `win:C:\x` means Windows even when
        // the model forgot the `target` parameter. Small models do this
        // constantly — they copy a path out of an earlier result and drop the
        // parameter — and honouring the prefix is both what the user meant and
        // what keeps the two-machine model coherent.
        let explicitTarget = ExecutionTarget.parse(args["target"] as? String)
        let rawPath = args["path"] as? String
        let pathTarget = rawPath.map { UnifiedPath.parse($0).target }

        let target: ExecutionTarget
        if explicitTarget == .windows || pathTarget == .windows {
            target = .windows
        } else {
            target = .ipad
        }
        guard target != .ipad else { return .local }

        guard remoteAvailable else {
            return .rejected(reason:
                "No remote computer is configured. Add one in Settings → Integrations → Remote Computer, "
                + "or omit `target` to run on the iPad.")
        }

        switch toolName {
        case "shell_execute":
            guard let command = (args["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
                return .rejected(reason: "shell_execute needs a non-empty `command`.")
            }
            let timeout = timeoutSeconds(args["timeout"])
            // A working directory is only meaningful in the remote machine's
            // own path syntax; a POSIX path here is a sign the model mixed the
            // two up, and passing it would produce a confusing shell error.
            var cwd: String?
            if let raw = args["cwd"] as? String ?? args["working_directory"] as? String {
                let parsed = UnifiedPath.parse(raw)
                guard parsed.target == .windows else {
                    return .rejected(reason:
                        "`\(raw)` is an iPad path but the command targets Windows. "
                        + "Use a Windows path such as C:\\\\Users\\\\… .")
                }
                cwd = parsed.path
            }
            return .shell(command: command, timeout: timeout, workingDirectory: cwd)

        case "file_read":
            guard let path = remotePath(rawPath) else {
                return .rejected(reason: pathProblem(rawPath, tool: "file_read"))
            }
            return .readFile(path: path)

        case "file_write":
            guard let path = remotePath(rawPath) else {
                return .rejected(reason: pathProblem(rawPath, tool: "file_write"))
            }
            guard let content = args["content"] as? String else {
                return .rejected(reason: "file_write needs a `content` string.")
            }
            return .writeFile(path: path, content: content,
                              append: boolValue(args["append"]) ?? false)

        case "file_edit":
            guard let path = remotePath(rawPath) else {
                return .rejected(reason: pathProblem(rawPath, tool: "file_edit"))
            }
            guard let old = args["old_string"] as? String, !old.isEmpty else {
                return .rejected(reason: "file_edit needs a non-empty `old_string`.")
            }
            guard let new = args["new_string"] as? String else {
                return .rejected(reason: "file_edit needs a `new_string` (use \"\" to delete).")
            }
            return .editFile(path: path, oldString: old, newString: new,
                             replaceAll: boolValue(args["replace_all"]) ?? false)

        default:
            // Every other tool is iPad-only by nature — the browser runs in
            // this app, memory is this device's, images are read from this
            // filesystem. Saying so beats silently running it locally, which
            // would have the model believe it screenshotted the PC.
            return .rejected(reason:
                "`\(toolName)` only runs on the iPad. Use shell_execute with target 'windows' "
                + "to do the equivalent on the PC.")
        }
    }

    // MARK: Helpers

    /// Validate and unqualify a path for the remote machine.
    private static func remotePath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parsed = UnifiedPath.parse(raw)
        guard parsed.scheme == .win, parsed.isValid else { return nil }
        return parsed.path
    }

    /// A specific diagnostic, so the model can fix the call instead of retrying
    /// the same one.
    private static func pathProblem(_ raw: String?, tool: String) -> String {
        guard let raw, !raw.isEmpty else { return "\(tool) needs a `path`." }
        let parsed = UnifiedPath.parse(raw)
        if parsed.scheme != .win {
            return "`\(raw)` isn't a Windows path. Prefix it with `win:` or use a drive letter, e.g. win:C:\\\\Users\\\\me\\\\file.txt"
        }
        if let problem = parsed.validate() {
            return "`\(raw)`: \(problem.localizedDescription)"
        }
        return "`\(raw)` can't be used as a Windows path."
    }

    /// Timeouts arrive as Int, Double or String depending on the model.
    static func timeoutSeconds(_ raw: Any?, default fallback: TimeInterval = 900) -> TimeInterval {
        let value: TimeInterval?
        switch raw {
        case let v as Int: value = TimeInterval(v)
        case let v as Double: value = v
        case let v as String: value = TimeInterval(v)
        case let v as NSNumber: value = v.doubleValue
        default: value = nil
        }
        guard let value, value > 0 else { return fallback }
        // Clamped: a model that asks for a 24-hour timeout would otherwise pin
        // a network request open for the life of the app.
        return min(value, 3600)
    }

    static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let v as Bool: return v
        case let v as Int: return v != 0
        case let v as String:
            switch v.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}
