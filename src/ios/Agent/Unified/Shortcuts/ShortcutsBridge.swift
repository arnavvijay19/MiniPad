//
//  ShortcutsBridge.swift
//  MinisApp
//
//  Running Apple Shortcuts from the agent, using only public mechanisms.
//
//  WHAT IPADOS ACTUALLY ALLOWS, STATED PLAINLY
//
//  There is no public API to enumerate a user's shortcuts. None. `Shortcuts`
//  exposes no list to third-party apps, App Intents describes only *our* app's
//  intents, and the shortcuts database is outside our sandbox. Any "list my
//  shortcuts" feature would have to be invented, and an agent that hallucinates
//  a shortcut name and then reports success is worse than one that admits it
//  cannot see the list.
//
//  So this file does not pretend. The agent learns about shortcuts from a
//  registry the *user* fills in — once, per shortcut they want the agent to be
//  able to run — and that registry is the honest, complete answer to "what can
//  you run?".
//
//  Running one is supported: `shortcuts://x-callback-url/run-shortcut` is a
//  documented URL interface, and x-callback-url returns the shortcut's output
//  to a callback URL. Two consequences that must be surfaced rather than hidden:
//
//    * It foregrounds the Shortcuts app. There is no supported way for a
//      third-party app to run a shortcut in the background. The screen changes,
//      and it changes back. A long agent run cannot silently sprinkle shortcut
//      calls through itself without the user noticing, and shouldn't try.
//    * A shortcut that doesn't end with "Stop and Output" returns nothing.
//      That's the shortcut's design, not a failure here, and the message says so.
//
//  Everything below is pure Foundation: URL construction, callback parsing, and
//  the pending-request bookkeeping. Unit-tested off-device.
//

import Foundation

// MARK: - Registry

/// One shortcut the user has told the agent about.
///
/// The user supplies the name (which must match the shortcut exactly, because
/// that is how the URL interface addresses it) and a description of what it
/// does. The description is what the model reasons over, so it is the field
/// worth prompting the user to write well.
struct ShortcutDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// Exact shortcut name as it appears in the Shortcuts app.
    var name: String
    /// What it does, in the user's words. Shown to the model.
    var summary: String
    /// What it expects as input, if anything.
    var inputKind: InputKind
    /// Whether it ends with "Stop and Output" and therefore returns something.
    var returnsOutput: Bool
    var enabled: Bool

    var id: String { name }

    enum InputKind: String, Codable, Hashable, Sendable, CaseIterable {
        case none
        case text
        /// A file or URL passed as text — Shortcuts coerces it.
        case url

        var promptHint: String {
            switch self {
            case .none: return "takes no input"
            case .text: return "takes text input"
            case .url: return "takes a URL or file path as input"
            }
        }
    }

    init(
        name: String,
        summary: String = "",
        inputKind: InputKind = .none,
        returnsOutput: Bool = false,
        enabled: Bool = true
    ) {
        self.name = name
        self.summary = summary
        self.inputKind = inputKind
        self.returnsOutput = returnsOutput
        self.enabled = enabled
    }
}

enum ShortcutRegistry {

    /// Prompt fragment describing the registered shortcuts.
    ///
    /// Returns nil when nothing is registered, so a user who never touches this
    /// feature pays zero tokens for it — which matters a great deal when the
    /// model has 32K of context and a 4B parameter budget.
    ///
    /// The "cannot list" sentence is deliberate. Without it a model asked "what
    /// shortcuts do I have?" will happily invent an answer; with it, it says
    /// what is actually true.
    static func promptFragment(_ shortcuts: [ShortcutDescriptor]) -> String? {
        let enabled = shortcuts.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        var lines = "<shortcuts>\n"
        lines += "Apple Shortcuts the user has registered. Run one with run_shortcut.\n"
        lines += "Running a shortcut briefly switches to the Shortcuts app and back — say so before you do it.\n"
        for shortcut in enabled.sorted(by: { $0.name < $1.name }) {
            var line = "- \(shortcut.name)"
            if !shortcut.summary.isEmpty { line += ": \(shortcut.summary)" }
            line += " (\(shortcut.inputKind.promptHint)"
            line += shortcut.returnsOutput ? ", returns output)" : ", returns nothing)"
            lines += line + "\n"
        }
        lines += "This is the complete list you can see; iOS gives no way to enumerate the user's other shortcuts.\n"
        lines += "</shortcuts>"
        return lines
    }

    /// Look up a registered shortcut, tolerating case and whitespace — the
    /// model will not reproduce the user's capitalisation reliably.
    static func find(_ name: String, in shortcuts: [ShortcutDescriptor]) -> ShortcutDescriptor? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return shortcuts.first { $0.name.lowercased() == needle }
            ?? shortcuts.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "")
                                  == needle.replacingOccurrences(of: " ", with: "") }
    }
}

// MARK: - URL construction

enum ShortcutsBridge {

    /// The callback host used in `x-success` / `x-error` / `x-cancel`.
    /// `minis://` is already registered by the app (Info.plist, "Minis Share").
    static let callbackScheme = "minis"
    static let callbackHost = "shortcut-callback"

    enum BuildError: Error, Equatable, LocalizedError {
        case emptyName
        case inputNotAccepted(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "A shortcut name is required."
            case .inputNotAccepted(let name):
                return "'\(name)' is registered as taking no input, so passing input would be ignored. Register it as accepting text if it does."
            }
        }
    }

    /// Build the URL that runs a shortcut and reports its result back.
    ///
    /// `token` correlates the callback with the waiting tool call — several
    /// runs can be outstanding, and matching them by name would resolve the
    /// wrong one when the same shortcut is invoked twice.
    static func runURL(
        name: String,
        input: String?,
        token: String,
        acceptsInput: Bool
    ) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BuildError.emptyName }
        if let input, !input.isEmpty, !acceptsInput {
            throw BuildError.inputNotAccepted(trimmed)
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"

        var items = [URLQueryItem(name: "name", value: trimmed)]
        if let input, !input.isEmpty {
            // `input=text` tells Shortcuts to treat `text` as the input value
            // rather than as a file reference.
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        items.append(URLQueryItem(name: "x-success", value: callbackURL(token: token, outcome: "success").absoluteString))
        items.append(URLQueryItem(name: "x-error", value: callbackURL(token: token, outcome: "error").absoluteString))
        items.append(URLQueryItem(name: "x-cancel", value: callbackURL(token: token, outcome: "cancel").absoluteString))
        components.queryItems = items

        guard let url = components.url else { throw BuildError.emptyName }
        return url
    }

    /// The callback Shortcuts will open when the run finishes.
    static func callbackURL(token: String, outcome: String) -> URL {
        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = callbackHost
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "outcome", value: outcome),
        ]
        // Force-unwrap is safe: every component is a literal or a token we
        // generated, so this cannot fail to compose.
        return components.url!
    }

    /// Probe URL for `canOpenURL`, to tell the user Shortcuts isn't installed
    /// rather than opening a URL that silently does nothing.
    static var probeURL: URL { URL(string: "shortcuts://")! }

    // MARK: - Callback parsing

    /// What came back from a shortcut run.
    enum Outcome: Equatable, Sendable {
        case success(result: String?)
        case failure(message: String)
        case cancelled

        var modelFacingText: String {
            switch self {
            case .success(let result):
                guard let result, !result.isEmpty else {
                    // A shortcut with no "Stop and Output" step returns
                    // nothing. That is its design, not a failure, and saying so
                    // stops the model retrying forever.
                    return "The shortcut ran. It returned no output — add a 'Stop and Output' step to the shortcut if you want a result back."
                }
                return result
            case .failure(let message):
                return "The shortcut failed: \(message)"
            case .cancelled:
                return "The shortcut was cancelled."
            }
        }
    }

    struct Callback: Equatable, Sendable {
        let token: String
        let outcome: Outcome
    }

    /// Parse a `minis://shortcut-callback?...` URL opened by Shortcuts.
    ///
    /// Returns nil for anything that isn't one of ours, so the app's existing
    /// deep-link router keeps handling every other `minis://` URL unchanged.
    static func parseCallback(_ url: URL) -> Callback? {
        guard url.scheme?.lowercased() == callbackScheme,
              url.host?.lowercased() == callbackHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let token = value("token"), !token.isEmpty else { return nil }

        switch value("outcome") {
        case "success":
            // Shortcuts appends its output as `result`. Some versions use
            // `x-source`/`result` casing variants, so both are accepted.
            let result = value("result") ?? value("Result")
            return Callback(token: token, outcome: .success(result: result))
        case "error":
            let message = value("errorMessage") ?? value("error") ?? "unknown error"
            return Callback(token: token, outcome: .failure(message: message))
        case "cancel":
            return Callback(token: token, outcome: .cancelled)
        default:
            return nil
        }
    }

    /// Fresh correlation token.
    static func makeToken() -> String {
        // Short and URL-safe. Collisions don't matter beyond a single app
        // session, and the pending table is keyed within one.
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }
}

// MARK: - Pending runs

/// Tracks shortcut runs that are waiting for their callback.
///
/// Needed because the round trip leaves the app entirely: the tool call
/// suspends, iOS foregrounds Shortcuts, and the answer arrives later through
/// `openURL`. Without correlation, two concurrent runs of the same shortcut
/// resolve into each other's tool results.
///
/// Pure logic — the async plumbing lives in the tool handler.
struct PendingShortcutRuns: Sendable {

    struct Pending: Sendable {
        let token: String
        let shortcutName: String
        let startedAt: Date
    }

    private var pending: [String: Pending] = [:]

    /// How long to wait before giving up on a callback.
    ///
    /// Generous, because "the user is looking at the Shortcuts app deciding
    /// whether to grant a permission" is a normal reason for a slow callback,
    /// and a premature timeout produces a tool result that says the shortcut
    /// failed when it is about to succeed.
    static let timeout: TimeInterval = 180

    init() {}

    mutating func register(token: String, shortcutName: String, now: Date = Date()) {
        pending[token] = Pending(token: token, shortcutName: shortcutName, startedAt: now)
    }

    /// Claim a callback. Returns nil for an unknown token — a stale callback
    /// from a previous app launch, or one the user triggered by hand.
    mutating func claim(token: String) -> Pending? {
        pending.removeValue(forKey: token)
    }

    /// Drop runs whose callback never arrived — the user switched away from
    /// Shortcuts, or the shortcut is still sitting on a permission prompt they
    /// abandoned. Without this the table grows for the life of the process.
    mutating func expire(now: Date = Date()) -> [Pending] {
        let stale = pending.values.filter { now.timeIntervalSince($0.startedAt) > Self.timeout }
        for entry in stale { pending.removeValue(forKey: entry.token) }
        return stale
    }

    var count: Int { pending.count }
    func contains(token: String) -> Bool { pending[token] != nil }
}
