//
//  MCPWireProtocol.swift
//  MinisApp
//
//  Model Context Protocol over Streamable HTTP — the wire format only.
//
//  WHY A NATIVE CLIENT WHEN MINIS ALREADY HAS ONE
//
//  Minis reaches MCP servers through `minis-mcp-cli`, a Python client running
//  *inside* the iSH sandbox. That is the right design for the general case: it
//  keeps the tool surface at zero (the agent discovers and calls MCP tools with
//  the shell it already has), it supports STDIO servers, and it needs no native
//  code. It stays exactly as it is.
//
//  It is the wrong design for the Windows execution target specifically:
//
//    * iSH is an x86 emulator. Every byte of an MCP response is parsed by
//      CPython running under emulation — on the order of a second of overhead
//      per call before the remote host has done any work. For a REPL round-trip
//      or a streaming build log that is the dominant cost.
//    * Cancellation is a signal to an emulated process, not a cancelled URL
//      task; a stop tap can't reliably tear down an in-flight HTTP request.
//    * A shell-mediated call can't carry a permission prompt, an endpoint
//      health indicator, or per-call provenance into the UI.
//
//  So the Windows target gets a native transport, and everything else keeps
//  using the CLI. Two paths, each where it's actually better.
//
//  This file contains no networking. It is the encode/decode half — JSON-RPC
//  framing, the MCP initialize/tools handshake, SSE parsing, and result
//  extraction — so it can be exercised exhaustively off-device. The URLSession
//  half lives in MCPHTTPClient.swift.
//
//  Reference: MCP "Streamable HTTP" transport, protocol revision 2025-06-18.
//

import Foundation

// MARK: - JSON value

/// A JSON value that survives a round trip without losing type information.
///
/// `[String: Any]` can't be Codable or Sendable, and Foundation's JSONSerialization
/// turns booleans into NSNumber, which then re-encodes `true` as `1` — a real
/// bug when an MCP tool has a boolean parameter. This enum avoids both.
indirect enum MCPValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPValue])
    case object([String: MCPValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool must be tried before Int: JSONDecoder will happily decode `true`
        // as Int 1 on some platforms, silently corrupting boolean arguments.
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([MCPValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: MCPValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrepresentable JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Build from the loosely-typed dictionaries the agent loop already uses
    /// for tool arguments (`[String: Any]` out of the provider layer).
    static func from(_ any: Any) -> MCPValue {
        switch any {
        case is NSNull: return .null
        case let v as MCPValue: return v
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(v)
        case let v as Int64: return .int(Int(v))
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(MCPValue.from))
        case let v as [String: Any]: return .object(v.mapValues(MCPValue.from))
        case let v as NSNumber:
            // NSNumber is where JSONSerialization hides booleans. The `as Bool`
            // case above catches CFBoolean once it has bridged; this is the
            // fallback for an NSNumber that reached us unbridged, identified by
            // its ObjC type encoding ("c", i.e. char, is how CFBoolean encodes).
            // JSONSerialization never produces a genuine Int8, so there is no
            // collision to worry about on this path.
            if String(cString: v.objCType) == "c" { return .bool(v.boolValue) }
            if v.doubleValue == v.doubleValue.rounded(), abs(v.doubleValue) < 9.2e18 {
                return .int(v.intValue)
            }
            return .double(v.doubleValue)
        default:
            return .string(String(describing: any))
        }
    }

    /// Back to the loose representation for call sites that still need it.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var objectValue: [String: MCPValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [MCPValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    subscript(key: String) -> MCPValue? { objectValue?[key] }
}

// MARK: - JSON-RPC framing

/// A JSON-RPC 2.0 request or notification. A notification is a request with no
/// `id`; the server must not answer it.
struct MCPRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int?
    let method: String
    let params: MCPValue?

    init(id: Int?, method: String, params: MCPValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    static func notification(_ method: String, params: MCPValue? = nil) -> MCPRequest {
        MCPRequest(id: nil, method: method, params: params)
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        // `id` is omitted entirely for notifications — encoding it as null
        // makes some servers treat it as a request and reply, which then
        // desynchronises the response correlation.
        if let id { try c.encode(id, forKey: .id) }
        try c.encode(method, forKey: .method)
        if let params { try c.encode(params, forKey: .params) }
    }

    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// A decoded JSON-RPC response frame.
struct MCPResponse: Decodable, Sendable {
    let id: Int?
    let result: MCPValue?
    let error: MCPErrorPayload?
    /// Set when the frame is a server→client request/notification rather than a
    /// response (progress notifications, logging, sampling requests).
    let method: String?
    let params: MCPValue?

    var isNotification: Bool { method != nil && id == nil }

    private enum CodingKeys: String, CodingKey { case id, result, error, method, params }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Servers in the wild send string ids even though we always send ints.
        if let i = try? c.decodeIfPresent(Int.self, forKey: .id) {
            self.id = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .id) {
            self.id = Int(s)
        } else {
            self.id = nil
        }
        self.result = try c.decodeIfPresent(MCPValue.self, forKey: .result)
        self.error = try c.decodeIfPresent(MCPErrorPayload.self, forKey: .error)
        self.method = try c.decodeIfPresent(String.self, forKey: .method)
        self.params = try c.decodeIfPresent(MCPValue.self, forKey: .params)
    }

    static func decode(_ data: Data) throws -> MCPResponse {
        try JSONDecoder().decode(MCPResponse.self, from: data)
    }
}

struct MCPErrorPayload: Decodable, Sendable, Equatable {
    let code: Int
    let message: String
    let data: MCPValue?
}

/// Everything that can go wrong talking to an MCP endpoint, in a shape that
/// produces a useful sentence for both the user and the model.
enum MCPError: Error, LocalizedError {
    case transport(String)
    case http(status: Int, body: String)
    case rpc(code: Int, message: String)
    case protocolViolation(String)
    case notInitialized
    case toolNotFound(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .transport(let d):
            return "Couldn't reach the endpoint: \(d)"
        case .http(let status, let body):
            let snippet = body.prefix(200)
            return "Endpoint returned HTTP \(status)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .rpc(let code, let message):
            return "Endpoint error \(code): \(message)"
        case .protocolViolation(let d):
            return "Unexpected response from the endpoint: \(d)"
        case .notInitialized:
            return "The endpoint session isn't established yet."
        case .toolNotFound(let name):
            return "The endpoint doesn't expose a '\(name)' tool."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// True for failures worth retrying once with backoff (the PC went to
    /// sleep, Wi-Fi roamed, the server restarted and dropped the session).
    /// A 4xx or an RPC-level error is the caller's fault and is never retried.
    var isTransient: Bool {
        switch self {
        case .transport: return true
        case .http(let status, _): return status >= 500 || status == 408 || status == 429
        case .rpc, .protocolViolation, .notInitialized, .toolNotFound, .cancelled: return false
        }
    }

    /// A dropped session (server restarted) is recoverable by re-running the
    /// initialize handshake rather than by retrying the same request verbatim.
    var requiresReinitialize: Bool {
        if case .http(let status, _) = self { return status == 404 || status == 401 }
        if case .notInitialized = self { return true }
        return false
    }
}

// MARK: - Protocol constants

enum MCPProtocol {
    /// Revision this client implements and advertises.
    static let version = "2025-06-18"
    /// Revisions accepted from a server. A server that negotiates down to an
    /// older revision still works for our purposes (initialize + tools/list +
    /// tools/call are stable across all of these).
    static let acceptedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let sessionHeader = "Mcp-Session-Id"
    static let versionHeader = "MCP-Protocol-Version"

    enum Method {
        static let initialize = "initialize"
        static let initialized = "notifications/initialized"
        static let toolsList = "tools/list"
        static let toolsCall = "tools/call"
        static let ping = "ping"
        static let cancelled = "notifications/cancelled"
    }
}

// MARK: - Handshake

/// Builds the `initialize` request.
///
/// `clientInfo` names Minis honestly. Some servers gate behaviour on it, and
/// misrepresenting the client to a server is exactly the kind of thing that
/// makes a fork unmaintainable.
enum MCPHandshake {
    static func initializeRequest(id: Int, clientName: String, clientVersion: String) -> MCPRequest {
        MCPRequest(
            id: id,
            method: MCPProtocol.Method.initialize,
            params: .object([
                "protocolVersion": .string(MCPProtocol.version),
                "capabilities": .object([
                    // We consume tools. We do not offer sampling (the server is
                    // never allowed to drive the user's model) or roots.
                    "tools": .object([:]),
                ]),
                "clientInfo": .object([
                    "name": .string(clientName),
                    "version": .string(clientVersion),
                ]),
            ])
        )
    }

    static let initializedNotification = MCPRequest.notification(MCPProtocol.Method.initialized)

    /// What the server told us about itself.
    struct ServerInfo: Sendable, Equatable {
        let name: String
        let version: String
        let protocolVersion: String
        let hasTools: Bool

        /// Rendered for the endpoint row in Settings.
        var summary: String {
            "\(name) \(version) · MCP \(protocolVersion)"
        }
    }

    static func parseInitializeResult(_ result: MCPValue) throws -> ServerInfo {
        guard let obj = result.objectValue else {
            throw MCPError.protocolViolation("initialize result was not an object")
        }
        let negotiated = obj["protocolVersion"]?.stringValue ?? MCPProtocol.version
        // An unrecognised revision is reported, not fatal: the three methods we
        // use have been stable across every published revision, and refusing to
        // talk to a newer server would age this client badly.
        let info = obj["serverInfo"]?.objectValue
        let caps = obj["capabilities"]?.objectValue
        return ServerInfo(
            name: info?["name"]?.stringValue ?? "MCP server",
            version: info?["version"]?.stringValue ?? "?",
            protocolVersion: negotiated,
            hasTools: caps?["tools"] != nil
        )
    }
}

// MARK: - Tools

/// One tool as advertised by the endpoint.
struct MCPToolDescriptor: Sendable, Hashable {
    let name: String
    let description: String
    /// Raw JSON Schema for the arguments. Kept verbatim: it is never shown to
    /// the model (that is the whole point of the adapter layer) but it is used
    /// to fit the endpoint's tools onto the unified verbs and to validate
    /// arguments before spending a network round trip.
    let inputSchema: MCPValue?

    /// Names of the schema's declared properties, lowercased.
    var parameterNames: Set<String> {
        guard let props = inputSchema?["properties"]?.objectValue else { return [] }
        return Set(props.keys.map { $0.lowercased() })
    }

    var requiredParameters: Set<String> {
        guard let req = inputSchema?["required"]?.arrayValue else { return [] }
        return Set(req.compactMap { $0.stringValue?.lowercased() })
    }
}

enum MCPToolList {
    static func request(id: Int, cursor: String? = nil) -> MCPRequest {
        var params: [String: MCPValue] = [:]
        if let cursor { params["cursor"] = .string(cursor) }
        return MCPRequest(id: id, method: MCPProtocol.Method.toolsList,
                          params: params.isEmpty ? .object([:]) : .object(params))
    }

    struct Page: Sendable {
        let tools: [MCPToolDescriptor]
        let nextCursor: String?
    }

    static func parse(_ result: MCPValue) throws -> Page {
        guard let obj = result.objectValue, let raw = obj["tools"]?.arrayValue else {
            throw MCPError.protocolViolation("tools/list result had no 'tools' array")
        }
        let tools = raw.compactMap { entry -> MCPToolDescriptor? in
            guard let o = entry.objectValue, let name = o["name"]?.stringValue else { return nil }
            return MCPToolDescriptor(
                name: name,
                description: o["description"]?.stringValue ?? "",
                inputSchema: o["inputSchema"] ?? o["input_schema"]
            )
        }
        return Page(tools: tools, nextCursor: obj["nextCursor"]?.stringValue)
    }
}

enum MCPToolCall {
    static func request(id: Int, name: String, arguments: [String: MCPValue]) -> MCPRequest {
        MCPRequest(
            id: id,
            method: MCPProtocol.Method.toolsCall,
            params: .object([
                "name": .string(name),
                "arguments": .object(arguments),
            ])
        )
    }

    /// A tool result, flattened to what a text-first agent actually consumes.
    struct Result: Sendable, Equatable {
        /// All text content blocks joined with newlines.
        let text: String
        /// True when the server marked the call as failed. Note this is an
        /// *application* error carried in a successful RPC — distinct from an
        /// `MCPError.rpc`, which means the call itself couldn't be made.
        let isError: Bool
        /// Base64 image blocks, kept for tools that return screenshots.
        let images: [(mimeType: String, base64: String)]
        /// `structuredContent` when the server provides it — Desktop Commander
        /// style servers return process ids and exit codes here rather than in
        /// prose, and parsing prose for a PID is how you get a flaky agent.
        let structured: MCPValue?

        static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.text == rhs.text && lhs.isError == rhs.isError
                && lhs.structured == rhs.structured
                && lhs.images.map(\.base64) == rhs.images.map(\.base64)
        }
    }

    static func parse(_ result: MCPValue) throws -> Result {
        guard let obj = result.objectValue else {
            throw MCPError.protocolViolation("tools/call result was not an object")
        }
        var texts: [String] = []
        var images: [(String, String)] = []
        for block in obj["content"]?.arrayValue ?? [] {
            guard let b = block.objectValue else { continue }
            switch b["type"]?.stringValue {
            case "text":
                if let t = b["text"]?.stringValue { texts.append(t) }
            case "image":
                if let data = b["data"]?.stringValue {
                    images.append((b["mimeType"]?.stringValue ?? "image/png", data))
                }
            case "resource":
                // Embedded resource: prefer its inline text, else name the URI
                // so the model knows something came back and can fetch it.
                if let res = b["resource"]?.objectValue {
                    if let t = res["text"]?.stringValue {
                        texts.append(t)
                    } else if let uri = res["uri"]?.stringValue {
                        texts.append("[resource] \(uri)")
                    }
                }
            default:
                break
            }
        }
        return Result(
            text: texts.joined(separator: "\n"),
            isError: obj["isError"]?.boolValue ?? false,
            images: images,
            structured: obj["structuredContent"]
        )
    }
}

// MARK: - SSE

/// Incremental parser for `text/event-stream`.
///
/// Written as a fed-bytes state machine rather than a line splitter over a
/// complete body because the whole reason the Windows target streams is to show
/// build output as it happens. It must therefore cope with a chunk boundary
/// landing anywhere — mid-field, mid-UTF8, between the two newlines that end an
/// event. Each of those is a test case.
struct SSEParser {
    /// One dispatched event. `data` has had the per-line `data: ` prefixes
    /// stripped and the lines rejoined with "\n", per the EventSource spec.
    struct Event: Equatable, Sendable {
        let event: String?
        let data: String
        let id: String?
        let retry: Int?
    }

    private var buffer = Data()
    private var pendingData: [String] = []
    private var pendingEvent: String?
    private var pendingID: String?
    private var pendingRetry: Int?
    /// Carries an incomplete multi-byte UTF-8 sequence across chunks.
    private var utf8Carry = Data()

    init() {}

    /// Feed a network chunk; get back every event that completed within it.
    mutating func feed(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []

        // Split on "\n". The spec also allows "\r\n" and a bare "\r"; we
        // normalise CR before splitting so all three behave identically.
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            var lineBytes = Data(lineData)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }   // strip CR

            let line: String
            if let s = String(data: utf8Carry + lineBytes, encoding: .utf8) {
                utf8Carry = Data()
                line = s
            } else {
                // Invalid UTF-8 at this boundary. Keep the bytes and try again
                // with the next line's bytes appended, which is what happens
                // when a code point straddles a chunk that also split a line.
                utf8Carry.append(lineBytes)
                utf8Carry.append(0x0A)
                continue
            }

            if line.isEmpty {
                if let event = flush() { events.append(event) }
                continue
            }
            // A line starting with ':' is a comment/heartbeat. Proxies and
            // keep-alive timers emit these constantly; dropping them silently
            // is required or every heartbeat dispatches an empty event.
            if line.hasPrefix(":") { continue }

            let (field, value) = Self.splitField(line)
            switch field {
            case "event": pendingEvent = value
            case "data": pendingData.append(value)
            case "id": pendingID = value
            case "retry": pendingRetry = Int(value)
            default: break   // unknown fields are ignored, per spec
            }
        }
        return events
    }

    /// Dispatch whatever is buffered. Called when the connection closes without
    /// a trailing blank line — common when a server just ends the response.
    mutating func finish() -> [Event] {
        if let event = flush() { return [event] }
        return []
    }

    private mutating func flush() -> Event? {
        defer {
            pendingData = []
            pendingEvent = nil
            pendingID = nil
            pendingRetry = nil
        }
        // An event with no data lines is not dispatched (spec), which is what
        // keeps bare `id:`-only keep-alives from surfacing.
        guard !pendingData.isEmpty else { return nil }
        return Event(
            event: pendingEvent,
            data: pendingData.joined(separator: "\n"),
            id: pendingID,
            retry: pendingRetry
        )
    }

    /// "field: value" → ("field", "value"). Exactly one leading space after the
    /// colon is removed, per spec; further spaces are data.
    private static func splitField(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}
