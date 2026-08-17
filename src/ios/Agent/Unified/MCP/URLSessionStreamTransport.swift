//
//  URLSessionStreamTransport.swift
//  MinisApp
//
//  The only part of the Windows execution path that touches URLSession.
//
//  Kept deliberately dumb: no retries, no MCP knowledge, no branching on
//  content type. Everything interesting lives above it in MCPHTTPClient, which
//  is testable because this seam exists.
//

import Foundation

/// URLSession-backed transport.
struct URLSessionStreamTransport: HTTPStreamTransport {

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// Build a session tuned for agent workloads.
    ///
    /// `timeoutIntervalForResource` is deliberately an hour: a test suite or a
    /// build legitimately produces no bytes for minutes, and the default
    /// 7-day/60-second pairing would either hang forever or kill work that is
    /// progressing fine. The per-request timeout is the one the caller controls.
    static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval
    ) async throws -> HTTPStreamResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw HTTPStreamError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HTTPStreamError.cancelled
        } catch {
            throw HTTPStreamError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPStreamError.network("non-HTTP response")
        }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headerMap[k] = v }
        }

        // Batch bytes into reasonably sized chunks. AsyncBytes yields one byte
        // at a time; handing single bytes to the SSE state machine on a
        // multi-megabyte build log is a measurable waste, and flushing on
        // newline keeps streamed output arriving line-by-line for the UI.
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var batch = Data()
                batch.reserveCapacity(4096)
                do {
                    for try await byte in bytes {
                        batch.append(byte)
                        if batch.count >= 4096 || byte == 0x0A {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty { continuation.yield(batch) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: HTTPStreamError.cancelled)
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: HTTPStreamError.cancelled)
                } catch {
                    continuation.finish(throwing: HTTPStreamError.network(error.localizedDescription))
                }
            }
            // Without this, abandoning the stream leaves the URLSession task
            // downloading a build log nobody is reading.
            continuation.onTermination = { _ in task.cancel() }
        }

        return HTTPStreamResponse(status: http.statusCode, headers: headerMap, body: stream)
    }
}
