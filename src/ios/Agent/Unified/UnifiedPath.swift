//
//  UnifiedPath.swift
//  MinisApp
//
//  One way to name a file, whichever machine it lives on.
//
//  WHAT THIS DELIBERATELY IS NOT
//
//  It is tempting to give the agent a synthetic mount tree —
//  /workspace/ipad, /workspace/linux, /workspace/windows — so every path looks
//  local. That would be a lie on iPadOS. The app cannot mount a remote SMB
//  share into its sandbox, cannot mount a File Provider directory as a POSIX
//  path, and cannot give iSH a view of an iCloud folder that behaves like a
//  local disk (files are evicted, downloads are async, security-scoped access
//  is time-limited). An agent that believes a fake mount is real will write to
//  a path that silently doesn't persist, which is the worst possible failure
//  for a personal computer agent.
//
//  So instead of faking a filesystem, this type makes *location explicit* and
//  keeps the real paths real. A path is `<scheme>:<path>`:
//
//      /var/minis/workspace/report.md          → iPad Linux sandbox (default)
//      ipad:/var/minis/workspace/report.md     → same, written explicitly
//      win:C:\Users\me\repo\main.py            → the Windows host
//      win:\\build01\share\out.log             → a UNC path on the Windows host
//      files:<bookmark>/Notes/todo.md          → a user-authorized iOS Files location
//      minis://workspace/report.md             → the app's existing URL scheme
//
//  A bare path with no scheme is an iPad Linux path. That single rule keeps
//  every existing tool call, every persisted chat history entry and every model
//  that has never heard of this type working exactly as before.
//
//  Pure Foundation, no app dependencies — unit-tested off-device.
//

import Foundation

// MARK: - Scheme

/// Where a path physically lives.
enum PathScheme: String, Codable, Sendable, CaseIterable, Hashable {
    /// The in-app Alpine Linux filesystem (iSH). POSIX paths.
    case ipad
    /// The remote Windows host. Windows paths (drive-letter or UNC).
    case win
    /// A user-authorized location in iOS Files, addressed through a
    /// security-scoped bookmark. Not a POSIX path the sandbox can open
    /// directly — access is brokered and may require a download first.
    case files
    /// The app's own resource URL scheme (`minis://workspace/...`), already
    /// understood by the browser tool and the file pickers.
    case minis

    /// Which machine this scheme's storage is attached to.
    var target: ExecutionTarget {
        switch self {
        case .ipad, .files, .minis: return .ipad
        case .win: return .windows
        }
    }
}

// MARK: - UnifiedPath

/// A parsed, scheme-qualified path.
///
/// Parsing never throws. A malformed path is still a `UnifiedPath` — it just
/// fails `validate()`. That split matters: the model should get a specific
/// diagnostic ("that Windows path has no drive letter") rather than a generic
/// parse failure that tells it nothing about how to retry.
struct UnifiedPath: Hashable, Sendable, CustomStringConvertible {
    let scheme: PathScheme
    /// The path as it exists on its own machine, with the scheme stripped and
    /// separators normalised for that machine.
    let path: String
    /// True when the caller wrote the scheme explicitly. Round-tripping keeps
    /// the user's own phrasing in tool results instead of rewriting it.
    let schemeWasExplicit: Bool

    init(scheme: PathScheme, path: String, schemeWasExplicit: Bool = true) {
        self.scheme = scheme
        self.path = Self.normalize(path, for: scheme)
        self.schemeWasExplicit = schemeWasExplicit
    }

    /// Canonical string form. A bare iPad path that arrived bare stays bare.
    var description: String {
        if scheme == .minis { return path }
        if scheme == .ipad && !schemeWasExplicit { return path }
        return "\(scheme.rawValue):\(path)"
    }

    /// Always-qualified form, for logs, provenance lines and anywhere two
    /// machines' paths sit next to each other and could be confused.
    var qualified: String {
        scheme == .minis ? path : "\(scheme.rawValue):\(path)"
    }

    var target: ExecutionTarget { scheme.target }

    // MARK: Parsing

    /// Parse a model- or user-supplied path. Never fails; see `validate()`.
    static func parse(_ raw: String) -> UnifiedPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // The app's own URL scheme is passed through untouched — the browser
        // tool and MinisURLPathDecoding already own its semantics.
        if trimmed.lowercased().hasPrefix("minis://") {
            return UnifiedPath(scheme: .minis, path: trimmed, schemeWasExplicit: true)
        }

        // A Windows drive letter is itself a "scheme-looking" prefix ("C:\..."),
        // so check for it BEFORE generic scheme splitting or `C:` parses as a
        // scheme named "c". A single alphabetic character followed by ':' is
        // never one of our schemes.
        if isDriveQualified(trimmed) {
            return UnifiedPath(scheme: .win, path: trimmed, schemeWasExplicit: false)
        }
        // A bare UNC path (\\host\share) can only be Windows.
        if trimmed.hasPrefix("\\\\") {
            return UnifiedPath(scheme: .win, path: trimmed, schemeWasExplicit: false)
        }

        if let colon = trimmed.firstIndex(of: ":") {
            let head = String(trimmed[trimmed.startIndex..<colon]).lowercased()
            if let scheme = PathScheme(rawValue: head) {
                let tail = String(trimmed[trimmed.index(after: colon)...])
                return UnifiedPath(scheme: scheme, path: tail, schemeWasExplicit: true)
            }
        }

        return UnifiedPath(scheme: .ipad, path: trimmed, schemeWasExplicit: false)
    }

    /// `C:\...`, `c:/...`, or bare `C:`.
    private static func isDriveQualified(_ s: String) -> Bool {
        var it = s.makeIterator()
        guard let first = it.next(), first.isLetter, let second = it.next(), second == ":" else {
            return false
        }
        guard let third = it.next() else { return true }   // bare "C:"
        return third == "\\" || third == "/"
    }

    // MARK: Normalisation

    /// Put separators in the form the owning machine actually uses, so a model
    /// that types `win:C:/Users/me` doesn't produce a path PowerShell has to
    /// guess at, and `ipad:\var\log` doesn't reach iSH with backslashes.
    private static func normalize(_ path: String, for scheme: PathScheme) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        switch scheme {
        case .win:
            // Preserve a leading `\\` (UNC) while converting the rest.
            let isUNC = trimmed.hasPrefix("\\\\") || trimmed.hasPrefix("//")
            let body = trimmed.replacingOccurrences(of: "/", with: "\\")
            if isUNC {
                let stripped = body.drop(while: { $0 == "\\" })
                return "\\\\" + stripped
            }
            return body
        case .ipad, .files:
            return trimmed.replacingOccurrences(of: "\\", with: "/")
        case .minis:
            return trimmed
        }
    }

    // MARK: Validation

    enum Problem: Error, Equatable, LocalizedError {
        case empty
        case notAbsolute(PathScheme)
        case windowsPathMissingRoot
        case traversal
        case nulByte

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Empty path."
            case .notAbsolute(let scheme):
                return "\(scheme.rawValue) paths must be absolute (start with '/')."
            case .windowsPathMissingRoot:
                return "Windows paths must start with a drive letter (C:\\…) or be a UNC path (\\\\host\\share\\…)."
            case .traversal:
                return "Path contains a '..' segment. Pass a fully-resolved absolute path."
            case .nulByte:
                return "Path contains a NUL byte."
            }
        }
    }

    /// Structural check only — says nothing about whether the file exists.
    ///
    /// `..` is rejected rather than resolved. Resolving would be wrong here:
    /// this type has no way to know whether an intermediate segment is a
    /// symlink, and on the Windows side the path is going over the wire to a
    /// shell that will resolve it itself. Rejecting keeps a `..` from being
    /// used to climb out of a directory the user scoped a permission to.
    func validate() -> Problem? {
        if path.isEmpty { return .empty }
        if path.contains("\0") { return .nulByte }

        switch scheme {
        case .ipad, .files:
            if !path.hasPrefix("/") { return .notAbsolute(scheme) }
        case .win:
            let isDrive = Self.isDriveQualified(path)
            let isUNC = path.hasPrefix("\\\\")
            if !isDrive && !isUNC { return .windowsPathMissingRoot }
        case .minis:
            break
        }

        let separators: CharacterSet = scheme == .win ? CharacterSet(charactersIn: "\\/")
                                                      : CharacterSet(charactersIn: "/")
        let segments = path.components(separatedBy: separators)
        if segments.contains("..") { return .traversal }

        return nil
    }

    var isValid: Bool { validate() == nil }

    // MARK: Components

    /// Final path component ("main.py"), or "" for a root path.
    var lastComponent: String {
        let separators: CharacterSet = scheme == .win ? CharacterSet(charactersIn: "\\/")
                                                      : CharacterSet(charactersIn: "/")
        return path.components(separatedBy: separators).last(where: { !$0.isEmpty }) ?? ""
    }

    /// Lowercased extension without the dot, or "" if there is none.
    var pathExtension: String {
        let name = lastComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Append a relative component using the owning machine's separator.
    func appending(_ component: String) -> UnifiedPath {
        let sep = String(scheme == .win ? "\\" : "/")
        var base = path
        while base.hasSuffix(sep) && base.count > 1 { base.removeLast() }
        let tail = component.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        return UnifiedPath(scheme: scheme, path: base + sep + tail, schemeWasExplicit: schemeWasExplicit)
    }

    // MARK: Provenance

    /// One short line telling the model (and the user) where this file
    /// physically is. Used in file-tool results whenever a path is remote or
    /// brokered, so a two-machine session can't drift about which copy is which.
    func provenance(windowsHost: String? = nil) -> String {
        switch scheme {
        case .ipad:
            return "iPad · Linux sandbox"
        case .win:
            return windowsHost.map { "Windows · \($0)" } ?? "Windows"
        case .files:
            return "iPad · Files (user-authorized)"
        case .minis:
            return "iPad · app workspace"
        }
    }
}

// MARK: - Cross-target transfer

/// An explicit copy between machines.
///
/// Explicit is the whole point. There is no background sync, no watched
/// folder, no "workspace mirroring" — those quietly move user data and are
/// impossible to reason about when two machines disagree. A file crosses the
/// network because the agent said so, in one named operation, with a stated
/// overwrite policy.
struct CrossTargetCopy: Sendable {
    let source: UnifiedPath
    let destination: UnifiedPath
    let overwrite: Bool

    init(source: UnifiedPath, destination: UnifiedPath, overwrite: Bool = false) {
        self.source = source
        self.destination = destination
        self.overwrite = overwrite
    }

    /// True when the two endpoints are on different machines and bytes have to
    /// travel over the network.
    var crossesMachines: Bool { source.target != destination.target }

    enum Problem: Error, Equatable, LocalizedError {
        case invalidSource(UnifiedPath.Problem)
        case invalidDestination(UnifiedPath.Problem)
        case sameLocation

        var errorDescription: String? {
            switch self {
            case .invalidSource(let p): return "Source path: \(p.localizedDescription)"
            case .invalidDestination(let p): return "Destination path: \(p.localizedDescription)"
            case .sameLocation: return "Source and destination are the same file."
            }
        }
    }

    func validate() -> Problem? {
        if let p = source.validate() { return .invalidSource(p) }
        if let p = destination.validate() { return .invalidDestination(p) }
        if source == destination { return .sameLocation }
        return nil
    }

    /// Human/model-facing summary used in permission prompts and tool results.
    /// A cross-machine copy is a consequential action, so the user is shown
    /// exactly what leaves the device and where it lands.
    var summary: String {
        let arrow = crossesMachines ? "⇢" : "→"
        return "\(source.qualified) \(arrow) \(destination.qualified)"
    }
}

// MARK: - Namespace description for the system prompt

enum UnifiedWorkspaceNamespace {

    /// The prompt fragment that teaches the path syntax.
    ///
    /// Injected only when a remote target is actually configured — an iPad-only
    /// user never pays these tokens. Kept terse on purpose: measured at ~95
    /// tokens (see ToolContextBudget), which is the entire permanent cost of
    /// two-machine addressing.
    static func promptFragment(windowsHost: String?) -> String {
        let host = windowsHost.map { " (\($0))" } ?? ""
        return """
        <execution_targets>
        You can run commands and read/write files on two machines:
        - iPad (default): the on-device Alpine Linux sandbox. Paths are normal absolute POSIX paths, e.g. /var/minis/workspace/report.md
        - Windows\(host): the user's PC. Prefix paths with `win:`, e.g. win:C:\\Users\\me\\repo\\main.py

        Pass `target: "windows"` to shell_execute / file_read / file_write / file_edit to act on the PC. Omit it for the iPad.
        Files do NOT sync between the machines. To move one, copy it explicitly.
        Always say which machine you acted on when you report back.
        </execution_targets>
        """
    }
}
