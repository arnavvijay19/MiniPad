import XCTest

// MARK: - Scripted transport

/// A transport that replays a scripted sequence of responses and records what
/// was sent.
///
/// This is what makes the client's genuinely hard paths testable without a
/// server: session-id capture, the re-handshake after a server restart,
/// correlation-id matching on a multiplexed SSE stream, and the cancellation
/// notice. Every one of those is invisible from a UI test and expensive to
/// reproduce by hand against a real PC.
private final class ScriptedTransport: HTTPStreamTransport, @unchecked Sendable {

    struct Recorded {
        let method: String
        let headers: [String: String]
        let body: String

        /// The JSON-RPC method name in the sent frame.
        var rpcMethod: String? {
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["method"] as? String
        }

        var rpcID: Int? {
            guard let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj["id"] as? Int
        }
    }

    enum Step {
        case json(status: Int, headers: [String: String], body: String)
        case sse(status: Int, headers: [String: String], chunks: [String])
        case failure(HTTPStreamError)
    }

    /// A `Mutex`-free critical section that is safe to enter from an async
    /// context. `NSLock.lock()` is unavailable in async functions (it can block
    /// a cooperative-pool thread), and this transport is called from one.
    private let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var steps: [Step] = []
        var sent: [Recorded] = []

        func withLock<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    var sent: [Recorded] { state.withLock { $0.sent } }

    init(steps: [Step]) { state.withLock { $0.steps = steps } }

    /// Convenience: answer any `initialize` / `tools/list` handshake, then run
    /// the caller's steps.
    static func withHandshake(toolNames: [String], then steps: [Step]) -> ScriptedTransport {
        let tools = toolNames.map { name in
            """
            {"name":"\(name)","description":"","inputSchema":{"type":"object",
            "properties":{"command":{"type":"string"},"pid":{"type":"string"},
            "input":{"type":"string"},"path":{"type":"string"},
            "old_string":{"type":"string"},"new_string":{"type":"string"},
            "content":{"type":"string"},"timeout_ms":{"type":"number"}},
            "required":["command"]}}
            """.replacingOccurrences(of: "\n", with: "")
        }.joined(separator: ",")
        return ScriptedTransport(steps: [
            .json(status: 200, headers: ["Content-Type": "application/json",
                                         "Mcp-Session-Id": "sess-1"],
                  body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"dc","version":"1.0"},"capabilities":{"tools":{}}}}"#),
            .json(status: 202, headers: [:], body: ""),
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":3,"result":{"tools":[\#(tools)]}}"#),
        ] + steps)
    }

    func send(
        url: URL, method: String, headers: [String: String], body: Data, timeout: TimeInterval
    ) async throws -> HTTPStreamResponse {
        let step: Step? = state.withLock { s in
            s.sent.append(Recorded(method: method, headers: headers,
                                   body: String(data: body, encoding: .utf8) ?? ""))
            return s.steps.isEmpty ? nil : s.steps.removeFirst()
        }
        guard let step else { throw HTTPStreamError.network("scripted transport exhausted") }

        switch step {
        case .failure(let error):
            throw error
        case .json(let status, let headers, let body):
            return HTTPStreamResponse(status: status, headers: headers, body: Self.stream([body]))
        case .sse(let status, let headers, let chunks):
            var merged = headers
            merged["Content-Type"] = "text/event-stream"
            return HTTPStreamResponse(status: status, headers: merged, body: Self.stream(chunks))
        }
    }

    private static func stream(_ chunks: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks where !chunk.isEmpty {
                continuation.yield(Data(chunk.utf8))
            }
            continuation.finish()
        }
    }
}

private struct NoSecrets: RemoteEndpointSecretStore {
    var tokens: [String: String] = [:]
    var env: [String: String] = [:]
    func bearerToken(endpointId: String) -> String? { tokens[endpointId] }
    func environmentValue(_ name: String) -> String? { env[name] }
}

// MARK: - Tests

final class MCPHTTPClientTests: XCTestCase {

    private func makeConfig(headers: [String: String] = [:], usesBearer: Bool = false)
        -> RemoteEndpointConfig {
        RemoteEndpointConfig(
            id: "ep1", displayName: "Desktop",
            urlString: "http://192.168.1.38:8766/mcp",
            usesBearerToken: usesBearer, headers: headers
        )
    }

    private func makeClient(_ transport: ScriptedTransport, secrets: NoSecrets = NoSecrets())
        -> MCPHTTPClient {
        MCPHTTPClient(config: makeConfig(), secrets: secrets, transport: transport,
                      clientName: "Minis", clientVersion: "1.10")
    }

    // MARK: Handshake

    func testHandshakeSendsInitializeThenInitializedThenToolsList() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        let client = makeClient(transport)

        let info = try await client.connect()
        XCTAssertEqual(info.name, "dc")

        let methods = transport.sent.compactMap(\.rpcMethod)
        XCTAssertEqual(methods, ["initialize", "notifications/initialized", "tools/list"])
    }

    func testSessionIDIsCapturedAndEchoedOnLaterRequests() async throws {
        // Without this, a Streamable HTTP server answers 404 to every request
        // after the handshake and the endpoint looks permanently broken.
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        let client = makeClient(transport)
        try await client.connect()

        XCTAssertNil(transport.sent[0].headers["Mcp-Session-Id"],
                     "initialize can't carry a session id yet")
        XCTAssertEqual(transport.sent[1].headers["Mcp-Session-Id"], "sess-1")
        XCTAssertEqual(transport.sent[2].headers["Mcp-Session-Id"], "sess-1")
    }

    func testAcceptHeaderAdvertisesBothResponseShapes() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        let client = makeClient(transport)
        try await client.connect()
        let accept = transport.sent[0].headers["Accept"] ?? ""
        XCTAssertTrue(accept.contains("application/json"))
        XCTAssertTrue(accept.contains("text/event-stream"))
    }

    func testCapabilitiesAreResolvedFromTheHandshake() async throws {
        let transport = ScriptedTransport.withHandshake(
            toolNames: ["start_process", "read_file"], then: [])
        let client = makeClient(transport)
        try await client.connect()

        let caps = await client.capabilities
        XCTAssertEqual(caps?.binding(.startProcess)?.toolName, "start_process")
        XCTAssertEqual(caps?.binding(.readFile)?.toolName, "read_file")
    }

    func testConcurrentConnectsRunOneHandshake() async throws {
        // The agent loop fans tool calls out concurrently; two handshakes would
        // race for the session id and one would win with a stale value.
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        let client = makeClient(transport)

        async let a = client.connect()
        async let b = client.connect()
        async let c = client.connect()
        _ = try await (a, b, c)

        let initializes = transport.sent.filter { $0.rpcMethod == "initialize" }
        XCTAssertEqual(initializes.count, 1)
    }

    func testFailedHandshakeLeavesNoHalfState() async throws {
        // A stale serverInfo after a failed handshake would make the next call
        // short-circuit and fail confusingly rather than retrying.
        let transport = ScriptedTransport(steps: [.failure(.network("no route to host"))])
        let client = makeClient(transport)

        do {
            _ = try await client.connect()
            XCTFail("expected a transport failure")
        } catch {}

        let info = await client.serverInfo
        let caps = await client.capabilities
        XCTAssertNil(info)
        XCTAssertNil(caps)
    }

    // MARK: Tool calls

    func testToolCallReturnsParsedResult() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hi"}],"structuredContent":{"pid":41208}}}"#),
        ])
        let client = makeClient(transport)
        let result = try await client.callTool(name: "start_process",
                                               arguments: ["command": .string("dir")])
        XCTAssertEqual(result.text, "hi")
        XCTAssertEqual(result.structured?["pid"]?.intValue, 41208)
    }

    func testRPCErrorsSurfaceAsMCPErrors() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad args"}}"#),
        ])
        let client = makeClient(transport)
        do {
            _ = try await client.callTool(name: "start_process", arguments: [:])
            XCTFail("expected an RPC error")
        } catch let error as MCPError {
            guard case .rpc(let code, let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "bad args")
        }
    }

    func testHTTPErrorCarriesStatusAndBody() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [
            .json(status: 500, headers: [:], body: "internal error"),
        ])
        let client = makeClient(transport)
        do {
            _ = try await client.callTool(name: "start_process", arguments: [:])
            XCTFail("expected an HTTP error")
        } catch let error as MCPError {
            guard case .http(let status, let body) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertTrue(body.contains("internal error"))
        }
    }

    // MARK: SSE responses

    func testSSEResponseIsConsumedAndCorrelated() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [
            .sse(status: 200, headers: [:], chunks: [
                "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"message\":\"compiling\"}}\n\n",
                "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}\n\n",
            ]),
        ])
        let client = makeClient(transport)

        let streamed = StreamedTextRecorder()
        let result = try await client.callTool(
            name: "start_process", arguments: [:],
            onStreamedText: { streamed.append($0) }
        )
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(streamed.all, ["compiling"],
                       "progress notifications reach the caller so a long build streams")
    }

    func testForeignResponseFramesOnTheStreamAreIgnored() async throws {
        // A multiplexed stream can carry another in-flight request's answer.
        // Mistaking it for ours would return the wrong command's output.
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [
            .sse(status: 200, headers: [:], chunks: [
                "data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"WRONG\"}]}}\n\n",
                "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"RIGHT\"}]}}\n\n",
            ]),
        ])
        let client = makeClient(transport)
        let result = try await client.callTool(name: "start_process", arguments: [:])
        XCTAssertEqual(result.text, "RIGHT")
    }

    func testSSEFramesSplitAcrossChunksStillResolve() async throws {
        let frame = "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}\n\n"
        let mid = frame.index(frame.startIndex, offsetBy: 30)
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [
            .sse(status: 200, headers: [:],
                 chunks: [String(frame[frame.startIndex..<mid]), String(frame[mid...])]),
        ])
        let client = makeClient(transport)
        let result = try await client.callTool(name: "start_process", arguments: [:])
        XCTAssertEqual(result.text, "ok")
    }

    // MARK: Reconnection

    func testA404TriggersOneReHandshakeAndRetry() async throws {
        // This is "the PC rebooted". Surfacing it raw would show the user a
        // scary protocol error for something the client can just recover from.
        var steps: [ScriptedTransport.Step] = [
            .json(status: 404, headers: [:], body: "unknown session"),
        ]
        // Re-handshake, then the successful retry.
        steps += [
            .json(status: 200, headers: ["Content-Type": "application/json",
                                         "Mcp-Session-Id": "sess-2"],
                  body: #"{"jsonrpc":"2.0","id":5,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"dc","version":"1.0"},"capabilities":{"tools":{}}}}"#),
            .json(status: 202, headers: [:], body: ""),
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":7,"result":{"tools":[{"name":"start_process","description":"","inputSchema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}]}}"#),
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"recovered"}]}}"#),
        ]
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: steps)
        let client = makeClient(transport)

        let result = try await client.callTool(name: "start_process", arguments: [:])
        XCTAssertEqual(result.text, "recovered")

        let initializes = transport.sent.filter { $0.rpcMethod == "initialize" }
        XCTAssertEqual(initializes.count, 2, "exactly one re-handshake")
        XCTAssertEqual(transport.sent.last?.headers["Mcp-Session-Id"], "sess-2",
                       "the retry uses the NEW session id")
    }

    func testASecondFailureIsNotRetriedAgain() async throws {
        var steps: [ScriptedTransport.Step] = [.json(status: 404, headers: [:], body: "")]
        steps += [
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":5,"result":{"protocolVersion":"2025-06-18"}}"#),
            .json(status: 202, headers: [:], body: ""),
            .json(status: 200, headers: ["Content-Type": "application/json"],
                  body: #"{"jsonrpc":"2.0","id":7,"result":{"tools":[]}}"#),
            .json(status: 404, headers: [:], body: "still gone"),
        ]
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: steps)
        let client = makeClient(transport)

        do {
            _ = try await client.callTool(name: "start_process", arguments: [:])
            XCTFail("expected the second 404 to propagate")
        } catch let error as MCPError {
            guard case .http(let status, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(status, 404)
        }
        XCTAssertEqual(transport.sent.filter { $0.rpcMethod == "initialize" }.count, 2)
    }

    // MARK: Headers and secrets

    func testBearerTokenIsAttachedWhenConfigured() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        var secrets = NoSecrets()
        secrets.tokens["ep1"] = "s3cret"
        let client = MCPHTTPClient(
            config: makeConfig(usesBearer: true), secrets: secrets,
            transport: transport, clientName: "Minis", clientVersion: "1.10"
        )
        try await client.connect()
        XCTAssertEqual(transport.sent[0].headers["Authorization"], "Bearer s3cret")
    }

    func testUnresolvedEnvironmentPlaceholderFailsLoudly() async throws {
        // Sending the literal "$$TOKEN" as a credential produces a confusing
        // 401 instead of the actionable "that variable isn't set".
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        let config = makeConfig(headers: ["X-Token": "$$MY_TOKEN"])
        let client = MCPHTTPClient(config: config, secrets: NoSecrets(), transport: transport,
                                   clientName: "Minis", clientVersion: "1.10")
        do {
            _ = try await client.connect()
            XCTFail("expected the missing variable to be reported")
        } catch let error as MCPError {
            XCTAssertTrue("\(error)".contains("MY_TOKEN"))
        }
    }

    func testResolvedEnvironmentPlaceholderIsSubstituted() async throws {
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        var secrets = NoSecrets()
        secrets.env["MY_TOKEN"] = "abc123"
        let client = MCPHTTPClient(config: makeConfig(headers: ["X-Token": "$$MY_TOKEN"]),
                                   secrets: secrets, transport: transport,
                                   clientName: "Minis", clientVersion: "1.10")
        try await client.connect()
        XCTAssertEqual(transport.sent[0].headers["X-Token"], "abc123")
    }

    func testClientIdentifiesItselfHonestly() async throws {
        // Misrepresenting the client to a server is exactly the kind of thing
        // that makes a fork unmaintainable.
        let transport = ScriptedTransport.withHandshake(toolNames: ["start_process"], then: [])
        let client = makeClient(transport)
        try await client.connect()
        XCTAssertTrue(transport.sent[0].body.contains("\"name\":\"Minis\""))
    }

    // MARK: Pagination

    func testToolListPaginationIsFollowed() async throws {
        let page1 = #"{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"start_process","description":"","inputSchema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}],"nextCursor":"p2"}}"#
        let page2 = #"{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"read_file","description":"","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]}}"#
        let transport = ScriptedTransport(steps: [
            .json(status: 200, headers: ["Content-Type": "application/json", "Mcp-Session-Id": "s"],
                  body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#),
            .json(status: 202, headers: [:], body: ""),
            .json(status: 200, headers: ["Content-Type": "application/json"], body: page1),
            .json(status: 200, headers: ["Content-Type": "application/json"], body: page2),
        ])
        let client = makeClient(transport)
        try await client.connect()

        let caps = await client.capabilities
        XCTAssertNotNil(caps?.binding(.startProcess))
        XCTAssertNotNil(caps?.binding(.readFile))
    }

    func testRepeatedCursorDoesNotLoopForever() async throws {
        // A server with a broken cursor would otherwise spin until the user
        // force-quits the app.
        let page = #"{"jsonrpc":"2.0","id":3,"result":{"tools":[],"nextCursor":"same"}}"#
        var steps: [ScriptedTransport.Step] = [
            .json(status: 200, headers: ["Content-Type": "application/json", "Mcp-Session-Id": "s"],
                  body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#),
            .json(status: 202, headers: [:], body: ""),
        ]
        steps += Array(repeating: .json(status: 200, headers: ["Content-Type": "application/json"],
                                        body: page), count: 30)
        let transport = ScriptedTransport(steps: steps)
        let client = makeClient(transport)
        try await client.connect()

        let listCalls = transport.sent.filter { $0.rpcMethod == "tools/list" }
        XCTAssertLessThanOrEqual(listCalls.count, 2, "the repeated cursor stops the walk")
    }

    // MARK: Probe

    func testProbeReportsFailureWithoutThrowing() async {
        let transport = ScriptedTransport(steps: [.failure(.network("host unreachable"))])
        let client = makeClient(transport)
        let outcome = await client.probe()
        guard case .failure(let error) = outcome else { return XCTFail("expected a failure") }
        XCTAssertTrue(error.isTransient)
    }
}

/// Thread-safe collector for the streaming callback.
private final class StreamedTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ text: String) {
        lock.lock(); storage.append(text); lock.unlock()
    }
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
