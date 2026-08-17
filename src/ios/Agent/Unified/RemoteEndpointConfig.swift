//
//  RemoteEndpointConfig.swift
//  MinisApp
//
//  User configuration for a remote execution host. Never application logic.
//
//  There is exactly one hardcoded thing in this file and it is the default
//  PORT — a convenience for the "Add endpoint" form's placeholder text, not a
//  value anything connects to. No address, no token, no hostname is compiled
//  into the app. The endpoint URL lives in UserDefaults (it is not a secret and
//  it belongs in iCloud-synced settings alongside the user's other endpoints);
//  the bearer token, if any, lives in the Keychain and is never written to a
//  file, a log, or a synced record.
//
//  Pure Foundation apart from the Keychain accessor, which is behind a protocol
//  so the config model itself is testable off-device.
//

import Foundation

// MARK: - Config

/// One remote computer the agent can execute on.
struct RemoteEndpointConfig: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity for settings rows and keychain lookup.
    let id: String
    /// User-facing name ("Desktop", "Work PC"). Shown in provenance lines so a
    /// two-machine session reads naturally.
    var displayName: String
    /// The MCP endpoint, e.g. `http://192.168.1.10:8766/mcp`. The example is
    /// generic on purpose: no real address belongs in the source.
    var urlString: String
    /// Which target this endpoint serves.
    var target: ExecutionTarget
    /// True when the endpoint needs an `Authorization: Bearer <token>` header.
    /// The token itself is in the Keychain under `id`.
    var usesBearerToken: Bool
    /// Extra headers the user configured (proxy auth, tunnel identifiers).
    /// Values may contain `$$VAR` placeholders resolved from the app's
    /// environment variables, matching the convention MCPStore already uses,
    /// so a user can avoid pasting a literal secret into a synced field.
    var headers: [String: String]
    /// Default per-call network timeout, seconds.
    var requestTimeout: TimeInterval
    /// Working directory commands start in, in Windows path syntax. Optional.
    var defaultWorkingDirectory: String?
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        displayName: String,
        urlString: String,
        target: ExecutionTarget = .windows,
        usesBearerToken: Bool = false,
        headers: [String: String] = [:],
        requestTimeout: TimeInterval = 120,
        defaultWorkingDirectory: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.urlString = urlString
        self.target = target
        self.usesBearerToken = usesBearerToken
        self.headers = headers
        self.requestTimeout = requestTimeout
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.enabled = enabled
    }

    var url: URL? { URL(string: urlString) }

    // MARK: Validation

    enum Problem: Error, Equatable, LocalizedError {
        case emptyURL
        case malformedURL
        case unsupportedScheme(String)
        case missingHost
        case plaintextOverInternet(host: String)

        var errorDescription: String? {
            switch self {
            case .emptyURL:
                return "Enter the endpoint URL, e.g. http://192.168.1.10:8766/mcp"
            case .malformedURL:
                return "That doesn't parse as a URL."
            case .unsupportedScheme(let s):
                return "Unsupported scheme '\(s)'. Use http or https."
            case .missingHost:
                return "The URL has no host."
            case .plaintextOverInternet(let host):
                return "\(host) isn't a private/local address, so plain http would send your commands unencrypted across the internet. Use https, or a VPN/tunnel that terminates locally."
            }
        }
    }

    /// Structural + safety validation.
    ///
    /// The plaintext rule is the one with teeth. Everything this endpoint does
    /// is arbitrary code execution on the user's PC, so an unauthenticated,
    /// unencrypted MCP endpoint reachable from the public internet is a remote
    /// shell for anyone on the path. Plain `http` is allowed to a private LAN
    /// address or loopback — which is the actual deployment, and where TLS
    /// would mean self-signed certificate management for no gain — and refused
    /// to anything routable.
    func validate() -> Problem? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyURL }
        guard let url = URL(string: trimmed) else { return .malformedURL }
        guard let scheme = url.scheme?.lowercased() else { return .unsupportedScheme("") }
        guard scheme == "http" || scheme == "https" else { return .unsupportedScheme(scheme) }
        guard let host = url.host, !host.isEmpty else { return .missingHost }
        if scheme == "http" && !Self.isPrivateOrLocal(host: host) {
            return .plaintextOverInternet(host: host)
        }
        return nil
    }

    var isValid: Bool { validate() == nil }

    /// RFC1918 / loopback / link-local / CGNAT / unique-local IPv6 / `.local`.
    static func isPrivateOrLocal(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".internal") { return true }
        if h == "::1" { return true }
        // IPv6 unique-local (fc00::/7) and link-local (fe80::/10).
        if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe8") || h.hasPrefix("fe9")
            || h.hasPrefix("fea") || h.hasPrefix("feb") {
            if h.contains(":") { return true }
        }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard octets.count == 4, let a = UInt8Value(octets[0]), let b = UInt8Value(octets[1]),
              UInt8Value(octets[2]) != nil, UInt8Value(octets[3]) != nil else {
            // Not a dotted-quad — a bare hostname on the LAN is common
            // (`desktop`, `nuc`). Treat a single-label name as local; anything
            // with a public-looking suffix is not.
            return !h.contains(".")
        }
        switch a {
        case 127: return true                                   // loopback
        case 10: return true                                    // 10/8
        case 172: return (16...31).contains(Int(b))             // 172.16/12
        case 192: return b == 168                               // 192.168/16
        case 169: return b == 254                               // link-local
        case 100: return (64...127).contains(Int(b))            // CGNAT 100.64/10
        default: return false
        }
    }

    private static func UInt8Value(_ s: String) -> UInt8? {
        guard !s.isEmpty, s.allSatisfy(\.isNumber), let v = Int(s), (0...255).contains(v) else { return nil }
        return UInt8(v)
    }

    /// Host label used in provenance lines and permission prompts.
    var hostLabel: String {
        if !displayName.isEmpty { return displayName }
        return url?.host ?? urlString
    }

    /// Redacted form for logs and diagnostics. Query strings sometimes carry
    /// tunnel tokens, so they never make it into a log line.
    var redactedURL: String {
        guard let url else { return "<invalid>" }
        var out = "\(url.scheme ?? "?")://\(url.host ?? "?")"
        if let port = url.port { out += ":\(port)" }
        out += url.path
        if url.query != nil { out += "?<redacted>" }
        return out
    }
}

// MARK: - Secret resolution

/// Supplies the bearer token for an endpoint. Split out so the transport and
/// the config model can be tested without a Keychain.
protocol RemoteEndpointSecretStore: Sendable {
    func bearerToken(endpointId: String) -> String?
    /// Resolve a `$$NAME` placeholder from the app's environment variables,
    /// mirroring MCPStore's convention.
    func environmentValue(_ name: String) -> String?
}

extension RemoteEndpointConfig {
    /// Final header set for a request, with placeholders resolved and the
    /// bearer token attached.
    ///
    /// A `$$NAME` that resolves to nothing is dropped rather than sent
    /// literally: sending the placeholder text as a credential value produces a
    /// confusing 401 instead of the actionable "that variable isn't set".
    func resolvedHeaders(secrets: RemoteEndpointSecretStore) -> (headers: [String: String], unresolved: [String]) {
        var out: [String: String] = [:]
        var unresolved: [String] = []
        for (key, raw) in headers {
            if raw.hasPrefix("$$") {
                let name = String(raw.dropFirst(2))
                if let value = secrets.environmentValue(name) {
                    out[key] = value
                } else {
                    unresolved.append(name)
                }
            } else {
                out[key] = raw
            }
        }
        if usesBearerToken, let token = secrets.bearerToken(endpointId: id), !token.isEmpty {
            out["Authorization"] = "Bearer \(token)"
        }
        return (out, unresolved)
    }
}
