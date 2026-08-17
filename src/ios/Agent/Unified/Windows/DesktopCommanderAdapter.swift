//
//  DesktopCommanderAdapter.swift
//  MinisApp
//
//  Fits whatever tools the user's Windows MCP endpoint actually exposes onto
//  the small set of verbs the unified executor needs.
//
//  WHY THIS LAYER EXISTS
//
//  The endpoint on the other side is the user's own Desktop Commander build.
//  Different builds — and different forks — name the same operation
//  differently (`read_file` vs `read_text_file`, `pid` vs `process_id`,
//  `timeout_ms` vs `timeout`), and a compact build may omit an operation
//  entirely. Two bad options were available:
//
//    (a) hardcode one tool set and break the moment the endpoint changes;
//    (b) hand all ~20 discovered tool schemas to the model and let it figure
//        it out — which is precisely the "permanent 30-100 tool catalog" that
//        makes a 4B model useless.
//
//  This is option (c): discover the endpoint's tools once per session, bind
//  them to verbs by name and by schema shape, emulate what's missing over the
//  shell verb, and expose *nothing* new to the model. The endpoint's tool
//  schemas never enter a prompt.
//
//  Pure Foundation — the binding logic is exercised against recorded tool
//  listings off-device.
//

import Foundation

// MARK: - Verbs

/// The operations the unified executor needs from a remote host.
///
/// Small on purpose. Anything not here is expressible as a shell command, and
/// a shell command is one round trip with no schema-matching risk.
enum RemoteVerb: String, CaseIterable, Sendable {
    /// Start a command; returns a process id.
    case startProcess
    /// Read buffered output from a running process.
    case readProcessOutput
    /// Write to a running process's stdin.
    case interactWithProcess
    /// Kill a running process.
    case terminateProcess
    /// Read a file's contents.
    case readFile
    /// Write a file wholesale.
    case writeFile
    /// Targeted string replacement inside a file.
    case applyPatch

    /// Tool names, in preference order, that have meant this verb in some
    /// Desktop Commander build. First match wins.
    var candidateToolNames: [String] {
        switch self {
        case .startProcess:
            return ["start_process", "execute_command", "run_command", "start_command", "shell", "exec"]
        case .readProcessOutput:
            return ["read_process_output", "read_output", "read_command_output", "get_process_output"]
        case .interactWithProcess:
            return ["interact_with_process", "send_input", "write_process_input", "interact"]
        case .terminateProcess:
            return ["force_terminate", "terminate_process", "kill_process", "stop_process"]
        case .readFile:
            return ["read_file", "read_text_file", "get_file", "cat"]
        case .writeFile:
            return ["write_file", "create_file", "put_file", "save_file"]
        case .applyPatch:
            return ["apply_patch", "edit_block", "edit_file", "patch_file", "replace_in_file", "str_replace"]
        }
    }

    /// Verbs the executor can synthesise from `startProcess` if the endpoint
    /// doesn't provide them. Everything false here is a hard capability gap
    /// that gets reported rather than faked.
    var isEmulatableOverShell: Bool {
        switch self {
        case .readFile, .writeFile, .applyPatch, .terminateProcess:
            return true
        case .startProcess, .readProcessOutput, .interactWithProcess:
            return false
        }
    }
}

// MARK: - Argument roles

/// A logical argument, decoupled from whatever the endpoint calls it.
enum RemoteArg: String, CaseIterable, Sendable {
    case command
    case processID
    case input
    case path
    case content
    case oldString
    case newString
    case timeoutMS
    case workingDirectory
    case shell
    case offset
    case length
    case replaceAll

    /// Parameter names, lowercased, that have carried this argument.
    var candidateNames: [String] {
        switch self {
        case .command:          return ["command", "cmd", "commandline", "command_line", "script"]
        case .processID:        return ["pid", "process_id", "processid", "id", "session_id"]
        case .input:            return ["input", "text", "stdin", "data"]
        case .path:             return ["path", "file_path", "filepath", "filename", "file"]
        case .content:          return ["content", "contents", "text", "data", "body"]
        case .oldString:        return ["old_string", "oldstring", "search", "old", "find", "pattern"]
        case .newString:        return ["new_string", "newstring", "replace", "new", "replacement"]
        case .timeoutMS:        return ["timeout_ms", "timeoutms", "timeout", "timeout_seconds", "timeout_sec"]
        case .workingDirectory: return ["cwd", "working_directory", "workingdirectory", "directory", "dir"]
        case .shell:            return ["shell", "interpreter"]
        case .offset:           return ["offset", "start", "start_line", "from"]
        case .length:           return ["length", "limit", "lines", "count"]
        case .replaceAll:       return ["replace_all", "replaceall", "expected_replacements", "all", "global"]
        }
    }

    /// True when the endpoint expresses this timeout in milliseconds. Used to
    /// convert our seconds-based API without guessing at the call site.
    static func timeoutIsMilliseconds(parameterName: String) -> Bool {
        let n = parameterName.lowercased()
        if n.contains("_ms") || n.hasSuffix("ms") { return true }
        if n.contains("sec") { return false }
        // A bare "timeout" is ambiguous. Desktop Commander and its forks use
        // milliseconds throughout, so that is the safer default here — an
        // over-long timeout wastes a wait, an under-short one truncates a
        // build log, and only the latter loses data.
        return true
    }
}

// MARK: - Binding

/// One resolved verb: which tool to call and what to name its arguments.
struct RemoteToolBinding: Sendable, Equatable {
    let verb: RemoteVerb
    let toolName: String
    /// Logical argument → the endpoint's parameter name.
    let argumentNames: [RemoteArg: String]
    /// Whether the bound tool's timeout parameter is in milliseconds.
    let timeoutIsMilliseconds: Bool

    func name(for arg: RemoteArg) -> String? { argumentNames[arg] }

    /// Build the `arguments` object for a call, dropping anything this tool
    /// doesn't declare. Silently dropping is right: an endpoint that has no
    /// `cwd` parameter must not receive one (strict servers reject unknown
    /// properties), and the caller has already been told the capability is
    /// absent via `RemoteCapabilities`.
    func arguments(_ values: [RemoteArg: MCPValue]) -> [String: MCPValue] {
        var out: [String: MCPValue] = [:]
        for (arg, value) in values {
            guard let name = argumentNames[arg] else { continue }
            out[name] = value
        }
        return out
    }
}

/// What the endpoint can and can't do, after discovery.
struct RemoteCapabilities: Sendable {
    let bindings: [RemoteVerb: RemoteToolBinding]
    /// Verbs with no tool, that the executor will emulate over the shell.
    let emulated: Set<RemoteVerb>
    /// Verbs with no tool and no emulation path.
    let missing: Set<RemoteVerb>
    /// Every tool the endpoint advertised, for the Settings diagnostics row.
    /// Never enters a prompt.
    let discoveredToolNames: [String]

    func binding(_ verb: RemoteVerb) -> RemoteToolBinding? { bindings[verb] }

    var canRunCommands: Bool { bindings[.startProcess] != nil }

    /// True when the endpoint supports genuine interactive sessions (REPLs,
    /// `git rebase -i`, an SSH prompt) rather than only fire-and-forget runs.
    var supportsInteractiveProcesses: Bool {
        bindings[.readProcessOutput] != nil && bindings[.interactWithProcess] != nil
    }

    /// One line for the endpoint row in Settings, and for the capability
    /// fragment the agent can read on demand.
    var summary: String {
        let ok = RemoteVerb.allCases.filter { bindings[$0] != nil }.count
        var parts = ["\(ok)/\(RemoteVerb.allCases.count) operations native"]
        if !emulated.isEmpty {
            parts.append("\(emulated.count) emulated over the shell")
        }
        if !missing.isEmpty {
            parts.append("unavailable: \(missing.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Resolver

enum DesktopCommanderAdapter {

    /// Bind the endpoint's advertised tools to our verbs.
    ///
    /// Matching is two-stage and deliberately conservative:
    ///   1. exact name match against the verb's candidate list, in order;
    ///   2. failing that, a schema-shape match — a tool whose required
    ///      parameters look exactly like the verb's (e.g. a single `command`).
    ///
    /// Stage 2 exists because a user's private fork may rename tools freely,
    /// but it only fires when the shape is unambiguous. A wrong binding here
    /// would run the wrong operation on the user's PC, so ambiguity always
    /// loses to "not bound" — which downgrades to shell emulation or an honest
    /// "unavailable".
    static func resolve(tools: [MCPToolDescriptor]) -> RemoteCapabilities {
        let byName = Dictionary(tools.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var bindings: [RemoteVerb: RemoteToolBinding] = [:]
        var claimed = Set<String>()

        // Stage 1 — exact name matches, highest-confidence first.
        for verb in RemoteVerb.allCases {
            for candidate in verb.candidateToolNames {
                guard let tool = byName[candidate], !claimed.contains(tool.name) else { continue }
                bindings[verb] = makeBinding(verb: verb, tool: tool)
                claimed.insert(tool.name)
                break
            }
        }

        // Stage 2 — shape matching for the verbs still unbound.
        for verb in RemoteVerb.allCases where bindings[verb] == nil {
            let matches = tools.filter { !claimed.contains($0.name) && shapeMatches(verb: verb, tool: $0) }
            guard matches.count == 1, let tool = matches.first else { continue }
            bindings[verb] = makeBinding(verb: verb, tool: tool)
            claimed.insert(tool.name)
        }

        var emulated = Set<RemoteVerb>()
        var missing = Set<RemoteVerb>()
        let hasShell = bindings[.startProcess] != nil
        for verb in RemoteVerb.allCases where bindings[verb] == nil {
            if verb.isEmulatableOverShell && hasShell {
                emulated.insert(verb)
            } else {
                missing.insert(verb)
            }
        }

        return RemoteCapabilities(
            bindings: bindings,
            emulated: emulated,
            missing: missing,
            discoveredToolNames: tools.map(\.name).sorted()
        )
    }

    private static func makeBinding(verb: RemoteVerb, tool: MCPToolDescriptor) -> RemoteToolBinding {
        let declared = declaredParameterNames(tool)
        var names: [RemoteArg: String] = [:]
        var used = Set<String>()

        // Resolve in a fixed order so that when two roles share a candidate
        // name (`text` is a candidate for both `input` and `content`), the role
        // that matters more for this verb claims it first.
        for arg in argumentPriority(for: verb) {
            for candidate in arg.candidateNames {
                guard let actual = declared[candidate], !used.contains(actual) else { continue }
                names[arg] = actual
                used.insert(actual)
                break
            }
        }

        let timeoutName = names[.timeoutMS]
        return RemoteToolBinding(
            verb: verb,
            toolName: tool.name,
            argumentNames: names,
            timeoutIsMilliseconds: timeoutName.map(RemoteArg.timeoutIsMilliseconds(parameterName:)) ?? true
        )
    }

    /// lowercased declared name → the declared name as written.
    private static func declaredParameterNames(_ tool: MCPToolDescriptor) -> [String: String] {
        guard let props = tool.inputSchema?["properties"]?.objectValue else { return [:] }
        var out: [String: String] = [:]
        for key in props.keys { out[key.lowercased()] = key }
        return out
    }

    /// Which roles get first claim on an ambiguous parameter name, per verb.
    private static func argumentPriority(for verb: RemoteVerb) -> [RemoteArg] {
        switch verb {
        case .startProcess:
            return [.command, .timeoutMS, .workingDirectory, .shell]
        case .readProcessOutput:
            return [.processID, .timeoutMS]
        case .interactWithProcess:
            return [.processID, .input, .timeoutMS]
        case .terminateProcess:
            return [.processID]
        case .readFile:
            return [.path, .offset, .length]
        case .writeFile:
            return [.path, .content]
        case .applyPatch:
            return [.path, .oldString, .newString, .replaceAll]
        }
    }

    /// Unambiguous shape signatures. Kept narrow on purpose — see `resolve`.
    private static func shapeMatches(verb: RemoteVerb, tool: MCPToolDescriptor) -> Bool {
        let required = tool.requiredParameters
        let all = tool.parameterNames
        func hasAny(_ arg: RemoteArg, in set: Set<String>) -> Bool {
            arg.candidateNames.contains(where: set.contains)
        }
        switch verb {
        case .startProcess:
            return hasAny(.command, in: required) && !hasAny(.processID, in: all) && !hasAny(.path, in: required)
        case .readProcessOutput:
            return hasAny(.processID, in: required) && !hasAny(.input, in: all)
        case .interactWithProcess:
            return hasAny(.processID, in: required) && hasAny(.input, in: required)
        case .terminateProcess:
            return hasAny(.processID, in: required) && all.count <= 2 && !hasAny(.input, in: all)
        case .readFile:
            return hasAny(.path, in: required) && !hasAny(.content, in: all) && !hasAny(.oldString, in: all)
        case .writeFile:
            return hasAny(.path, in: required) && hasAny(.content, in: required) && !hasAny(.oldString, in: all)
        case .applyPatch:
            return hasAny(.path, in: required) && hasAny(.oldString, in: required) && hasAny(.newString, in: required)
        }
    }
}

// MARK: - Shell emulation

/// Builds PowerShell one-liners for the verbs a compact endpoint doesn't
/// expose natively.
///
/// Every payload travels as base64. That is not paranoia: a build log, a Python
/// script and a JSON blob all contain characters that break at least one of
/// PowerShell's quoting rules, and a file write that silently mangles a quote
/// is a corruption bug in the user's own repository. Base64 has exactly one
/// escaping rule and it is "there isn't one".
enum WindowsShellEmulation {

    /// Read a file as base64 so the bytes survive the shell verbatim.
    /// Returns base64 on stdout, or a line starting with `MINIS_ERR:`.
    static func readFileCommand(path: String) -> String {
        let quoted = singleQuoted(path)
        return "try { [Convert]::ToBase64String([IO.File]::ReadAllBytes(\(quoted))) } "
             + "catch { \"MINIS_ERR:$($_.Exception.Message)\" }"
    }

    /// Write bytes to a file, creating parent directories.
    static func writeFileCommand(path: String, contents: Data) -> String {
        let quoted = singleQuoted(path)
        let b64 = contents.base64EncodedString()
        return "try { "
             + "$p = \(quoted); "
             + "$d = Split-Path -Parent $p; "
             + "if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }; "
             + "[IO.File]::WriteAllBytes($p, [Convert]::FromBase64String('\(b64)')); "
             + "\"MINIS_OK:$((Get-Item -LiteralPath $p).Length)\" "
             + "} catch { \"MINIS_ERR:$($_.Exception.Message)\" }"
    }

    /// Exact-string replacement, done with `String.IndexOf`/`Replace` rather
    /// than PowerShell's `-replace` so the needle is never interpreted as a
    /// regular expression — a literal `.` or `(` in the old string would
    /// otherwise match the wrong text and corrupt the user's file.
    ///
    /// Returns nil for an empty `oldString`: matching the empty string has no
    /// sensible occurrence count and would spin the counting loop forever.
    /// Callers surface that as an argument error, which is what it is.
    static func applyPatchCommand(path: String, oldString: String, newString: String, replaceAll: Bool) -> String? {
        guard !oldString.isEmpty else { return nil }
        let quoted = singleQuoted(path)
        let oldB64 = Data(oldString.utf8).base64EncodedString()
        let newB64 = Data(newString.utf8).base64EncodedString()
        // Whole-file replace when replacing all; a single splice otherwise, so
        // the untouched remainder of the file is byte-identical.
        let rewrite = replaceAll
            ? "$t.Replace($o, $n)"
            : "$t.Remove($t.IndexOf($o), $o.Length).Insert($t.IndexOf($o), $n)"
        return "try { "
             + "$p = \(quoted); "
             + "$t = [IO.File]::ReadAllText($p); "
             + "$o = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(oldB64)')); "
             + "$n = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(newB64)')); "
             + "$c = 0; $j = 0; while (($j = $t.IndexOf($o, $j)) -ge 0) { $c++; $j += $o.Length }; "
             + "if ($c -eq 0) { \"MINIS_ERR:old_string not found\" } "
             + "elseif ($c -gt 1 -and -not $\(replaceAll ? "true" : "false")) { \"MINIS_ERR:old_string matched $c times; pass replace_all or include more surrounding context\" } "
             + "else { [IO.File]::WriteAllText($p, \(rewrite)); \"MINIS_OK:$c\" } "
             + "} catch { \"MINIS_ERR:$($_.Exception.Message)\" }"
    }

    static func terminateCommand(pid: String) -> String {
        // `Stop-Process -Id` on a pid that already exited is an error, not a
        // no-op, and cancel() is documented as idempotent — so swallow it.
        "try { Stop-Process -Id \(sanitizePID(pid)) -Force -ErrorAction Stop; \"MINIS_OK\" } "
        + "catch { \"MINIS_OK:already-exited\" }"
    }

    /// PowerShell single-quoted literal: the only escape inside `'...'` is `''`.
    static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A pid reaches us as an opaque string from the endpoint. It is
    /// interpolated into a command line, so anything non-numeric is stripped
    /// rather than trusted — a malicious or buggy endpoint must not be able to
    /// append a second statement here.
    static func sanitizePID(_ pid: String) -> String {
        let digits = pid.filter(\.isNumber)
        return digits.isEmpty ? "0" : String(digits.prefix(10))
    }

    /// Outcome markers the commands above print.
    enum Marker {
        static let ok = "MINIS_OK"
        static let error = "MINIS_ERR:"
    }

    /// Outcome of an emulated command: either the detail that followed
    /// `MINIS_OK:` (often empty) or the message that followed `MINIS_ERR:`.
    enum Outcome: Equatable {
        case ok(detail: String)
        case failed(message: String)

        var isOK: Bool { if case .ok = self { return true }; return false }
    }

    /// Interpret the output of an emulated command.
    static func parseOutcome(_ output: String) -> Outcome {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Scan lines rather than only the last one: PowerShell may prepend
        // progress records or a stray warning before our marker.
        for line in trimmed.split(separator: "\n").reversed() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix(Marker.error) {
                return .failed(message: String(l.dropFirst(Marker.error.count)))
            }
            if l.hasPrefix(Marker.ok) {
                let detail = l.dropFirst(Marker.ok.count)
                return .ok(detail: detail.hasPrefix(":") ? String(detail.dropFirst()) : "")
            }
        }
        // No marker at all: the command didn't reach our epilogue (the shell
        // died, the endpoint truncated). Treat as a failure carrying whatever
        // came back, rather than silently reporting success.
        return .failed(message: trimmed.isEmpty ? "no output from the remote shell" : trimmed)
    }
}
