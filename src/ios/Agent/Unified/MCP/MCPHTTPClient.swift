//
//  MCPHTTPClient.swift
//  MinisApp
//
//  MCP over Streamable HTTP: session lifecycle, request correlation, streaming.
//
//  WHY A NATIVE CLIENT WHEN MINIS ALREADY HAS ONE
//
//  Minis reaches MCP servers through `minis-mcp-cli`, a Python client running
//  *inside* the iSH sandbox. That is the right design for the general case: it
//  keeps the agent's tool surface at zero (the agent discovers and calls MCP
//  tools with the shell it already has), it supports STDIO servers, and it
//  needs no native code. It stays exactly as it is.
//
//  It is the wrong design for the Windows execution target specifically:
//
//    * iSH is an x86 emulator. Every byte of an MCP response is parsed by
//      CPython under emulation — on the order of a second of overhead per call
//      before the remote host has done any work. For a REPL round trip or a
//      streaming build log that is the dominant cost.
//    * Cancellation is a signal to an emulated process, not a cancelled URL
//      task; a stop tap can't reliably tear down an in-flight HTTP request, and
//      the PC keeps building.
//    * A shell-mediated call can't carry a permission prompt, an endpoint
//      health indicator, or per-call provenance into the UI.
//
//  So the Windows target gets a native transport and everything else keeps
//  using the CLI. Two paths, each where it is actually better.
//
//  Networking is behind `HTTPStreamTransport`, so everything in this file —
//  the handshake, session-id capture, the re-handshake after a server restart,
//  SSE consumption, correlation, cancellation notices — is exercised off-device
//  against a scripted transport.
//
//  Reference: MCP "Streamable HTTP" transport, protocol revision 2025-06-18.
//

import Foundation

/// A live, initialized connection to one MCP endpoint.
///
/// An actor because the request-id counter, the session id and the re-handshake
/// are shared mutable state touched from concurrent tool calls — the agent loop
/// fans several tools out at once (AIChatViewModel+ConcurrentTools), so this is
/// a real race rather than a theoretical one.
actor MCPHTTPClient {

    // MARK: State

    private let config: RemoteEndpointConfig
    private let secrets: RemoteEndpointSecretStore
    private let transport: any HTTPStreamTransport
    private let clientName: String
    private let clientVersion: String

    private var nextRequestID = 1
    private var mcpSessionID: String?
    private var negotiatedVersion: String = MCPProtocol.version
    private(set) var serverInfo: MCPHandshake.ServerInfo?
    private(set) var capabilities: RemoteCapabilities?
    /// Guards against two concurrent callers both running the handshake.
    private var handshakeTask: Task<MCPHandshake.ServerInfo, Error>?

    init(
        config: RemoteEndpointConfig,
        secrets: RemoteEndpointSecretStore,
        transport: any HTTPStreamTransport,
        clientName: String,
        clientVersion: String
    ) {
        self.config = config
        self.secrets = secrets
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    var endpointConfig: RemoteEndpointConfig { config }

    // MARK: Handshake

    /// Establish (or reuse) the session and discover the endpoint's tools.
    @discardableResult
    func connect() async throws -> MCPHandshake.ServerInfo {
        if let serverInfo, capabilities != nil { return serverInfo }
        if let handshakeTask { return try await handshakeTask.value }
        let task = Task { try await performHandshake() }
        handshakeTask = task
        defer { handshakeTask = nil }
        do {
            return try await task.value
        } catch {
            // A failed handshake must not leave half-state behind, or the next
            // call short-circuits on a stale serverInfo and fails confusingly.
            serverInfo = nil
            capabilities = nil
            mcpSessionID = nil
            throw error
        }
    }

    private func performHandshake() async throws -> MCPHandshake.ServerInfo {
        mcpSessionID = nil
        let id = takeRequestID()
        let request = MCPHandshake.initializeRequest(id: id, clientName: clientName, clientVersion: clientVersion)
        let (response, headers) = try await send(request, expectResponse: true, correlationID: id)
        guard let result = try unwrap(response) else {
            throw MCPError.protocolViolation("initialize returned no result")
        }
        let info = try MCPHandshake.parseInitializeResult(result)
        mcpSessionID = headers[MCPProtocol.sessionHeader.lowercased()]
        negotiatedVersion = info.protocolVersion
        serverInfo = info

        // The spec requires this notification before any other request. It is
        // best-effort: a server that answers 4xx to it still works for tools,
        // and failing the whole connection over it would be worse than useless.
        _ = try? await send(MCPHandshake.initializedNotification, expectResponse: false)

        capabilities = DesktopCommanderAdapter.resolve(tools: try await listAllTools())
        return info
    }

    /// Force a fresh handshake — used after a 404 (server restarted) and by the
    /// "Test connection" button.
    func reconnect() async throws -> MCPHandshake.ServerInfo {
        serverInfo = nil
        mcpSessionID = nil
        capabilities = nil
        return try await connect()
    }

    // MARK: Tools

    private func listAllTools() async throws -> [MCPToolDescriptor] {
        var out: [MCPToolDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        // Bounded, and cycle-detecting: a server with a broken cursor that
        // returns the same page forever would otherwise spin here until the
        // user force-quits.
        for _ in 0..<20 {
            let id = takeRequestID()
            let (response, _) = try await send(MCPToolList.request(id: id, cursor: cursor),
                                               expectResponse: true, correlationID: id)
            guard let result = try unwrap(response) else { break }
            let page = try MCPToolList.parse(result)
            out.append(contentsOf: page.tools)
            guard let next = page.nextCursor, !next.isEmpty, seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        return out
    }

    /// Invoke a tool by its endpoint name.
    func callTool(
        name: String,
        arguments: [String: MCPValue],
        onStreamedText: (@Sendable (String) -> Void)? = nil
    ) async throws -> MCPToolCall.Result {
        try await connect()
        do {
            return try await performToolCall(name: name, arguments: arguments, onStreamedText: onStreamedText)
        } catch let error as MCPError where error.requiresReinitialize {
            // The PC restarted mid-session, or the session expired. Re-handshake
            // once and retry; a second failure is real and propagates.
            _ = try await reconnect()
            return try await performToolCall(name: name, arguments: arguments, onStreamedText: onStreamedText)
        }
    }

    private func performToolCall(
        name: String,
        arguments: [String: MCPValue],
        onStreamedText: (@Sendable (String) -> Void)?
    ) async throws -> MCPToolCall.Result {
        let requestID = takeRequestID()
        let request = MCPToolCall.request(id: requestID, name: name, arguments: arguments)
        do {
            let (response, _) = try await send(request, expectResponse: true,
                                               correlationID: requestID, onStreamedText: onStreamedText)
            guard let result = try unwrap(response) else {
                throw MCPError.protocolViolation("tools/call returned no result")
            }
            return try MCPToolCall.parse(result)
        } catch MCPError.cancelled {
            // Tearing down our side isn't enough — without this the PC keeps
            // running the build the user just cancelled. Detached because the
            // current Task is already cancelled, so any await on it would
            // return instantly and the notice would never leave the device.
            Task.detached { [weak self] in
                await self?.notifyCancelled(requestID: requestID, reason: "user cancelled")
            }
            throw MCPError.cancelled
        }
    }

    /// Reachability probe for the Settings row. Never throws — the caller wants
    /// to render a status, not handle an error.
    func probe() async -> Result<MCPHandshake.ServerInfo, MCPError> {
        do {
            return .success(try await reconnect())
        } catch let error as MCPError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    // MARK: Transport

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func unwrap(_ response: MCPResponse?) throws -> MCPValue? {
        guard let response else { return nil }
        if let error = response.error {
            throw MCPError.rpc(code: error.code, message: error.message)
        }
        return response.result
    }

    private func requestHeaders() throws -> [String: String] {
        var out: [String: String] = [
            "Content-Type": "application/json",
            // Advertising both is what lets the server answer with a single
            // JSON object for a fast call and an SSE stream for a slow one.
            "Accept": "application/json, text/event-stream",
            MCPProtocol.versionHeader: negotiatedVersion,
        ]
        if let mcpSessionID { out[MCPProtocol.sessionHeader] = mcpSessionID }
        let (configured, unresolved) = config.resolvedHeaders(secrets: secrets)
        if !unresolved.isEmpty {
            throw MCPError.transport(
                "these environment variables are referenced by the endpoint's headers but aren't set: "
                + unresolved.joined(separator: ", ")
            )
        }
        for (k, v) in configured { out[k] = v }
        return out
    }

    /// Send one JSON-RPC frame and collect the answer.
    ///
    /// Returns the response matching `correlationID` (or the first response
    /// frame when none is given), plus the lowercased response headers.
    private func send(
        _ request: MCPRequest,
        expectResponse: Bool,
        correlationID: Int? = nil,
        onStreamedText: (@Sendable (String) -> Void)? = nil
    ) async throws -> (MCPResponse?, [String: String]) {
        guard let url = config.url else { throw MCPError.transport("invalid endpoint URL") }
        let body: Data
        do {
            body = try request.jsonData()
        } catch {
            throw MCPError.protocolViolation("could not encode request: \(error.localizedDescription)")
        }

        let response: HTTPStreamResponse
        do {
            response = try await transport.send(
                url: url, method: "POST", headers: try requestHeaders(),
                body: body, timeout: config.requestTimeout
            )
        } catch HTTPStreamError.cancelled {
            throw MCPError.cancelled
        } catch let error as HTTPStreamError {
            if case .network(let detail) = error { throw MCPError.transport(detail) }
            throw MCPError.transport(String(describing: error))
        }

        // 202 Accepted with no body is the correct answer to a notification.
        if response.status == 202 || !expectResponse {
            try? await drain(response.body)
            return (nil, response.headers)
        }
        guard (200...299).contains(response.status) else {
            let text = (try? await collectText(response.body, limit: 2000)) ?? ""
            throw MCPError.http(status: response.status, body: text)
        }

        if response.isEventStream {
            let decoded = try await consumeSSE(response.body, correlationID: correlationID,
                                               onStreamedText: onStreamedText)
            return (decoded, response.headers)
        }

        var data = Data()
        do {
            for try await chunk in response.body { data.append(chunk) }
        } catch HTTPStreamError.cancelled {
            throw MCPError.cancelled
        } catch {
            throw MCPError.transport(error.localizedDescription)
        }
        guard !data.isEmpty else { return (nil, response.headers) }
        do {
            return (try MCPResponse.decode(data), response.headers)
        } catch {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            throw MCPError.protocolViolation("could not decode response: \(snippet)")
        }
    }

    private func drain(_ body: AsyncThrowingStream<Data, Error>) async throws {
        for try await _ in body {}
    }

    private func collectText(_ body: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> String {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return String(data: data.prefix(limit), encoding: .utf8) ?? ""
    }

    /// Read an SSE body until the frame we're waiting for arrives.
    ///
    /// Server→client notifications encountered on the way (progress updates,
    /// log messages) are surfaced through `onStreamedText`, which is what makes
    /// a long remote build show output as it happens instead of a spinner
    /// followed by a wall of text.
    private func consumeSSE(
        _ body: AsyncThrowingStream<Data, Error>,
        correlationID: Int?,
        onStreamedText: (@Sendable (String) -> Void)?
    ) async throws -> MCPResponse? {
        var parser = SSEParser()
        var matched: MCPResponse?

        func handle(_ event: SSEParser.Event) -> Bool {
            guard let data = event.data.data(using: .utf8),
                  let frame = try? MCPResponse.decode(data) else { return false }
            if frame.isNotification {
                if let text = Self.progressText(frame) { onStreamedText?(text) }
                return false
            }
            // A response whose id doesn't match ours belongs to another
            // in-flight request multiplexed on the same stream; skip it rather
            // than mistaking it for our answer.
            if let correlationID, frame.id != correlationID { return false }
            matched = frame
            return true
        }

        do {
            for try await chunk in body {
                for event in parser.feed(chunk) where handle(event) { return matched }
            }
            for event in parser.finish() where handle(event) { return matched }
        } catch HTTPStreamError.cancelled {
            throw MCPError.cancelled
        } catch {
            throw MCPError.transport(error.localizedDescription)
        }
        return matched
    }

    /// Pull human-readable text out of a server notification, if it has any.
    private static func progressText(_ frame: MCPResponse) -> String? {
        guard let params = frame.params?.objectValue else { return nil }
        if let message = params["message"]?.stringValue { return message }
        if let data = params["data"]?.stringValue { return data }
        if let data = params["data"]?.objectValue, let text = data["text"]?.stringValue { return text }
        return nil
    }

    /// Best-effort cancellation notice so the remote stops working too.
    /// Fire-and-forget by design: we're already tearing down, and a failure to
    /// deliver must never mask the original cancellation.
    func notifyCancelled(requestID: Int, reason: String) async {
        let notification = MCPRequest.notification(
            MCPProtocol.Method.cancelled,
            params: .object(["requestId": .int(requestID), "reason": .string(reason)])
        )
        _ = try? await send(notification, expectResponse: false)
    }
}
