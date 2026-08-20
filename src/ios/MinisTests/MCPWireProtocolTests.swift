import XCTest

/// Wire-format coverage for the native MCP client.
///
/// The SSE parser gets the most attention here. It is a fed-bytes state machine
/// whose whole job is to survive a chunk boundary landing in an arbitrary
/// place, and every one of those boundaries is a place where a streamed build
/// log can silently lose a line. Those cases can't be reached from a UI test,
/// so they are pinned here.
final class MCPWireProtocolTests: XCTestCase {

    // MARK: - MCPValue

    func testBooleansSurviveARoundTripAsBooleans() throws {
        // The bug this pins: JSONSerialization represents `true` as an
        // NSNumber, and a naive re-encode emits `1`. An MCP tool with a boolean
        // parameter then receives an integer and rejects the call.
        let value = MCPValue.object(["flag": .bool(true), "count": .int(1)])
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"flag\":true"), json)
        XCTAssertTrue(json.contains("\"count\":1"), json)

        let decoded = try JSONDecoder().decode(MCPValue.self, from: data)
        XCTAssertEqual(decoded["flag"], .bool(true))
        XCTAssertEqual(decoded["count"], .int(1))
    }

    func testFromAnyPreservesTypes() {
        XCTAssertEqual(MCPValue.from(true), .bool(true))
        XCTAssertEqual(MCPValue.from(42), .int(42))
        XCTAssertEqual(MCPValue.from("s"), .string("s"))
        XCTAssertEqual(MCPValue.from([1, 2]), .array([.int(1), .int(2)]))
        XCTAssertEqual(MCPValue.from(["k": "v"]), .object(["k": .string("v")]))
    }

    func testJSONSerializationKeepsOneAsIntegerNotBool() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{\"flag\":true,\"display\":[1,2]}"#.utf8))
        let dict = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(MCPValue.from(dict["flag"] as Any), .bool(true))
        XCTAssertEqual(MCPValue.from(dict["display"] as Any), .array([.int(1), .int(2)]))
    }

    func testNestedStructuresRoundTrip() throws {
        let original = MCPValue.object([
            "a": .array([.int(1), .string("x"), .bool(false), .null]),
            "b": .object(["c": .double(1.5)]),
        ])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MCPValue.self, from: data), original)
    }

    func testAccessorsCoerceLeniently() {
        // Endpoints are inconsistent about whether a pid is a number or a
        // string; coercion here saves a special case at every call site.
        XCTAssertEqual(MCPValue.string("42").intValue, 42)
        XCTAssertEqual(MCPValue.int(1).boolValue, true)
        XCTAssertEqual(MCPValue.string("yes").boolValue, true)
        XCTAssertNil(MCPValue.string("maybe").boolValue)
    }

    // MARK: - JSON-RPC framing

    func testNotificationOmitsIDEntirely() throws {
        // Encoding `"id": null` makes some servers treat a notification as a
        // request and answer it, which then desynchronises correlation.
        let json = String(data: try MCPRequest.notification("notifications/initialized").jsonData(),
                          encoding: .utf8)!
        XCTAssertFalse(json.contains("\"id\""), json)
        XCTAssertTrue(json.contains("\"jsonrpc\":\"2.0\""))
    }

    func testRequestIncludesID() throws {
        let json = String(data: try MCPRequest(id: 7, method: "tools/list").jsonData(), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"id\":7"), json)
    }

    func testResponseAcceptsStringIDs() throws {
        // Not all servers echo the id's type. Failing to coerce here would make
        // every response look uncorrelated and every call time out.
        let data = Data(#"{"jsonrpc":"2.0","id":"5","result":{"ok":true}}"#.utf8)
        XCTAssertEqual(try MCPResponse.decode(data).id, 5)
    }

    func testErrorFramesDecode() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no such tool"}}"#.utf8)
        let response = try MCPResponse.decode(data)
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(response.error?.message, "no such tool")
    }

    func testNotificationFramesAreIdentifiedAsSuch() throws {
        let data = Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"message":"building"}}"#.utf8)
        let response = try MCPResponse.decode(data)
        XCTAssertTrue(response.isNotification)
        XCTAssertEqual(response.params?["message"]?.stringValue, "building")
    }

    // MARK: - Error classification

    func testTransientClassification() {
        // Retrying a 4xx just wastes a round trip; retrying a 503 recovers from
        // the PC having been asleep.
        XCTAssertTrue(MCPError.transport("timeout").isTransient)
        XCTAssertTrue(MCPError.http(status: 503, body: "").isTransient)
        XCTAssertTrue(MCPError.http(status: 429, body: "").isTransient)
        XCTAssertFalse(MCPError.http(status: 400, body: "").isTransient)
        XCTAssertFalse(MCPError.rpc(code: -32601, message: "").isTransient)
        XCTAssertFalse(MCPError.cancelled.isTransient)
    }

    func testReinitializeClassification() {
        // 404 is how a Streamable HTTP server says "I don't know that session"
        // — i.e. it restarted. That needs a new handshake, not a retry.
        XCTAssertTrue(MCPError.http(status: 404, body: "").requiresReinitialize)
        XCTAssertTrue(MCPError.notInitialized.requiresReinitialize)
        XCTAssertFalse(MCPError.http(status: 500, body: "").requiresReinitialize)
    }

    // MARK: - Handshake parsing

    func testInitializeResultParses() throws {
        let result = MCPValue.object([
            "protocolVersion": .string("2025-06-18"),
            "serverInfo": .object(["name": .string("desktop-commander"), "version": .string("1.4.0")]),
            "capabilities": .object(["tools": .object([:])]),
        ])
        let info = try MCPHandshake.parseInitializeResult(result)
        XCTAssertEqual(info.name, "desktop-commander")
        XCTAssertEqual(info.version, "1.4.0")
        XCTAssertTrue(info.hasTools)
        XCTAssertEqual(info.summary, "desktop-commander 1.4.0 · MCP 2025-06-18")
    }

    func testInitializeResultToleratesAnOlderOrNewerRevision() throws {
        // Refusing to talk to a server that negotiated a different revision
        // would age this client badly — initialize/tools/list/tools/call have
        // been stable across every published revision.
        let result = MCPValue.object(["protocolVersion": .string("2099-01-01")])
        let info = try MCPHandshake.parseInitializeResult(result)
        XCTAssertEqual(info.protocolVersion, "2099-01-01")
    }

    // MARK: - tools/list

    func testToolListParses() throws {
        let result = MCPValue.object([
            "tools": .array([
                .object([
                    "name": .string("start_process"),
                    "description": .string("Run a command"),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["command": .object(["type": .string("string")])]),
                        "required": .array([.string("command")]),
                    ]),
                ])
            ]),
            "nextCursor": .string("page2"),
        ])
        let page = try MCPToolList.parse(result)
        XCTAssertEqual(page.tools.count, 1)
        XCTAssertEqual(page.tools[0].name, "start_process")
        XCTAssertEqual(page.tools[0].parameterNames, ["command"])
        XCTAssertEqual(page.tools[0].requiredParameters, ["command"])
        XCTAssertEqual(page.nextCursor, "page2")
    }

    func testToolListRejectsAMissingToolsArray() {
        XCTAssertThrowsError(try MCPToolList.parse(.object(["oops": .int(1)])))
    }

    // MARK: - tools/call

    func testToolCallResultFlattensTextBlocks() throws {
        let result = MCPValue.object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("line one")]),
                .object(["type": .string("text"), "text": .string("line two")]),
            ]),
        ])
        let parsed = try MCPToolCall.parse(result)
        XCTAssertEqual(parsed.text, "line one\nline two")
        XCTAssertFalse(parsed.isError)
    }

    func testToolCallResultKeepsStructuredContent() throws {
        // Parsing a pid out of prose is how you get a flaky agent; structured
        // content is the reliable path and must survive parsing.
        let result = MCPValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("started")])]),
            "structuredContent": .object(["pid": .int(41208)]),
        ])
        let parsed = try MCPToolCall.parse(result)
        XCTAssertEqual(parsed.structured?["pid"]?.intValue, 41208)
    }

    func testToolCallApplicationErrorIsDistinctFromRPCError() throws {
        // `isError: true` inside a successful RPC means "the tool ran and
        // failed" — a very different thing from "the call couldn't be made",
        // and the model needs to be able to tell them apart.
        let result = MCPValue.object([
            "content": .array([.object(["type": .string("text"), "text": .string("file not found")])]),
            "isError": .bool(true),
        ])
        XCTAssertTrue(try MCPToolCall.parse(result).isError)
    }

    func testToolCallResultExtractsImagesAndResources() throws {
        let result = MCPValue.object([
            "content": .array([
                .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("QUJD")]),
                .object(["type": .string("resource"),
                         "resource": .object(["uri": .string("file:///x.log")])]),
            ]),
        ])
        let parsed = try MCPToolCall.parse(result)
        XCTAssertEqual(parsed.images.count, 1)
        XCTAssertEqual(parsed.images[0].mimeType, "image/png")
        XCTAssertTrue(parsed.text.contains("file:///x.log"))
    }

    // MARK: - SSE parser

    private func events(feeding chunks: [String]) -> [SSEParser.Event] {
        var parser = SSEParser()
        var out: [SSEParser.Event] = []
        for chunk in chunks { out += parser.feed(Data(chunk.utf8)) }
        out += parser.finish()
        return out
    }

    func testSingleEvent() {
        let out = events(feeding: ["data: hello\n\n"])
        XCTAssertEqual(out, [SSEParser.Event(event: nil, data: "hello", id: nil, retry: nil)])
    }

    func testEventFieldsAreCaptured() {
        let out = events(feeding: ["event: message\nid: 7\nretry: 500\ndata: x\n\n"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].event, "message")
        XCTAssertEqual(out[0].id, "7")
        XCTAssertEqual(out[0].retry, 500)
    }

    func testMultipleDataLinesJoinWithNewline() {
        let out = events(feeding: ["data: a\ndata: b\n\n"])
        XCTAssertEqual(out[0].data, "a\nb")
    }

    func testChunkBoundaryMidField() {
        // The critical case: the network split the payload in the middle of a
        // field name. A line-splitting parser drops this event entirely.
        let out = events(feeding: ["da", "ta: hel", "lo\n", "\n"])
        XCTAssertEqual(out.map(\.data), ["hello"])
    }

    func testChunkBoundaryBetweenTheTwoTerminatingNewlines() {
        let out = events(feeding: ["data: one\n", "\ndata: two\n\n"])
        XCTAssertEqual(out.map(\.data), ["one", "two"])
    }

    func testChunkBoundaryInsideAMultiByteCodePoint() {
        // A UTF-8 sequence split across chunks must not corrupt the payload —
        // build logs contain non-ASCII (paths, error arrows, CJK filenames).
        let full = Data("data: héllo →\n\n".utf8)
        var parser = SSEParser()
        var out: [SSEParser.Event] = []
        // Split at every possible byte offset; every split must yield the same
        // event exactly once.
        for split in 1..<full.count {
            parser = SSEParser()
            out = parser.feed(full.prefix(split))
            out += parser.feed(full.suffix(from: split))
            out += parser.finish()
            XCTAssertEqual(out.map(\.data), ["héllo →"], "split at byte \(split)")
        }
    }

    func testCRLFLineEndings() {
        let out = events(feeding: ["data: hello\r\n\r\n"])
        XCTAssertEqual(out.map(\.data), ["hello"])
    }

    func testCommentLinesAreIgnored() {
        // Proxies and keep-alive timers emit `:` heartbeats constantly.
        // Dispatching them as empty events would flood the caller.
        let out = events(feeding: [": keep-alive\ndata: real\n\n"])
        XCTAssertEqual(out.map(\.data), ["real"])
    }

    func testEventWithNoDataIsNotDispatched() {
        let out = events(feeding: ["id: 1\n\n", "data: real\n\n"])
        XCTAssertEqual(out.map(\.data), ["real"])
    }

    func testExactlyOneSpaceAfterColonIsStripped() {
        let out = events(feeding: ["data:  two-leading-spaces\n\n"])
        XCTAssertEqual(out[0].data, " two-leading-spaces")
    }

    func testFieldWithNoColon() {
        let out = events(feeding: ["data\ndata: x\n\n"])
        XCTAssertEqual(out[0].data, "\nx", "a bare `data` line contributes an empty value")
    }

    func testTrailingEventWithoutBlankLineIsFlushedOnFinish() {
        // Servers routinely just end the response after the last event.
        // Without the finish() flush the final frame — usually the actual
        // result — would be dropped.
        let out = events(feeding: ["data: last\n"])
        XCTAssertEqual(out.map(\.data), ["last"])
    }

    func testUnknownFieldsAreIgnored() {
        let out = events(feeding: ["banana: yes\ndata: x\n\n"])
        XCTAssertEqual(out.map(\.data), ["x"])
    }

    func testManyEventsInOneChunk() {
        let chunk = (0..<50).map { "data: \($0)\n\n" }.joined()
        let out = events(feeding: [chunk])
        XCTAssertEqual(out.count, 50)
        XCTAssertEqual(out.last?.data, "49")
    }
}
