//
//  HTTPStreamTransport.swift
//  MinisApp
//
//  The narrow seam between the MCP client and the network.
//
//  MCPHTTPClient needs exactly one thing from the network: "POST this body and
//  give me back a status, some headers, and a stream of bytes". Expressing that
//  as a protocol rather than reaching for URLSession directly buys two things:
//
//    * The client's real logic — session-id capture, the re-handshake after a
//      server restart, SSE consumption, correlation-id matching, cancellation
//      notices — becomes testable against a scripted transport, with no server
//      and no device. Those paths are where the bugs live, and they are exactly
//      the paths that are impossible to exercise in a UI test.
//    * The one genuinely platform-bound file shrinks to ~40 lines of URLSession
//      plumbing with no branching in it.
//

import Foundation

/// A streaming HTTP response, reduced to what MCP needs.
struct HTTPStreamResponse: Sendable {
    let status: Int
    /// Header names lowercased. HTTP/2 lowercases them anyway, and the MCP spec
    /// names headers in title case (`Mcp-Session-Id`), so normalising once here
    /// removes a whole class of "works over HTTP/1.1, breaks over HTTP/2" bug.
    let headers: [String: String]
    let body: AsyncThrowingStream<Data, Error>

    init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var contentType: String { header("content-type")?.lowercased() ?? "" }
    var isEventStream: Bool { contentType.contains("text/event-stream") }
}

/// Something that can perform a streaming HTTP request.
protocol HTTPStreamTransport: Sendable {
    func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> HTTPStreamResponse
}

/// Transport-level failures, before any MCP framing is involved.
enum HTTPStreamError: Error, Equatable {
    case cancelled
    case network(String)
}
