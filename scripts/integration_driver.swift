//
//  integration_driver.swift
//  Driven by scripts/integration_test_mcp.sh — not part of the app target.
//
//  Exercises the real MCPHTTPClient, DesktopCommanderAdapter and
//  WindowsExecutor against a live MCP server over a real socket. Assertions are
//  plain functions rather than XCTest so this stays a single executable with no
//  test-runner dependency.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Tiny assertion harness

/// Locked rather than a top-level `var`: top-level state in `main.swift` is
/// MainActor-isolated, and the scenarios run in a detached Task.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var checks = 0

    func record(_ passed: Bool, _ what: String, detail: String = "") {
        lock.lock()
        checks += 1
        if !passed { failures.append(what) }
        let count = checks
        lock.unlock()
        _ = count
        print(passed ? "  ok    \(what)" : "  FAIL  \(what)\(detail)")
    }

    var summary: (passed: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        return (checks - failures.count, checks)
    }

    var isClean: Bool {
        lock.lock(); defer { lock.unlock() }
        return failures.isEmpty
    }
}

let results = Results()

func check(_ condition: Bool, _ what: String) {
    results.record(condition, what)
}

func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    results.record(a == b, what,
                   detail: a == b ? "" : "\n          expected: \(b)\n          actual:   \(a)")
}

func checkContains(_ haystack: String, _ needle: String, _ what: String) {
    let ok = haystack.contains(needle)
    results.record(ok, what,
                   detail: ok ? "" : "\n          '\(needle)' not in: \(haystack.prefix(300))")
}

// MARK: - Setup

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: Driver <scenario> <url> <sandbox>\n".utf8))
    exit(2)
}
let scenario = arguments[1]
let endpointURL = arguments[2]
let sandbox = arguments[3]

let config = RemoteEndpointConfig(
    id: "integration", displayName: "MockPC", urlString: endpointURL
)

func makeClient() -> MCPHTTPClient {
    MCPHTTPClient(
        config: config, secrets: NoSecrets(), transport: LinuxStreamTransport(),
        clientName: "Minis", clientVersion: "integration"
    )
}

// MARK: - Scenarios

func scenarioFullSurface() async throws {
    let client = makeClient()
    let info = try await client.connect()
    checkEqual(info.name, "mock-desktop-commander", "handshake reports the server name")
    checkEqual(info.protocolVersion, "2025-06-18", "protocol version negotiated")

    guard let caps = await client.capabilities else {
        return check(false, "capabilities were discovered")
    }
    // Every verb should bind natively on the full surface.
    for verb in RemoteVerb.allCases {
        check(caps.binding(verb) != nil, "verb \(verb.rawValue) bound natively")
    }
    check(caps.emulated.isEmpty, "nothing needs shell emulation on the full surface")
    check(caps.supportsInteractiveProcesses, "interactive processes are supported")

    let executor = WindowsExecutor(client: client, config: config)

    // Run a command for real.
    let result = try await executor.run(
        ExecutionRequest(target: .windows, command: "echo hello-from-integration", timeout: 20),
        onOutput: { _ in }
    )
    checkContains(result.output, "hello-from-integration", "command output came back")
    check(result.state.isSuccess, "zero exit reported as success")
    checkContains(result.modelFacingText(hostLabel: config.hostLabel),
                  "[ran on Windows (MockPC)]", "remote provenance is in the model-facing text")

    // A nonzero exit must be reported as a failure, not silently swallowed.
    let failing = try await executor.run(
        ExecutionRequest(target: .windows, command: "exit 3", timeout: 20),
        onOutput: { _ in }
    )
    checkEqual(failing.state.exitCode, 3, "nonzero exit code parsed")
    check(!failing.state.isSuccess, "nonzero exit is not success")

    // Write, read back, patch, read again — real files on disk.
    try await executor.writeFile(path: "notes.txt", contents: "alpha\nbeta\n")
    let (read, _) = try await executor.readFile(path: "notes.txt")
    checkEqual(read, "alpha\nbeta\n", "file round-trips through write_file/read_file")

    try await executor.applyPatch(path: "notes.txt", oldString: "beta",
                                  newString: "gamma", replaceAll: false)
    let (patched, _) = try await executor.readFile(path: "notes.txt")
    checkEqual(patched, "alpha\ngamma\n", "apply_patch edited the file")

    // The file really changed on disk, not just in the server's answer.
    let onDisk = (try? String(contentsOfFile: sandbox + "/notes.txt", encoding: .utf8)) ?? ""
    checkEqual(onDisk, "alpha\ngamma\n", "the change is visible on the filesystem")

    // Content that breaks naive quoting must survive verbatim.
    let tricky = "quote\" back`tick $var 'single'\nCRLF\r\n漢字 \\backslash"
    try await executor.writeFile(path: "tricky.txt", contents: tricky)
    let (trickyBack, _) = try await executor.readFile(path: "tricky.txt")
    checkEqual(trickyBack, tricky, "shell-hostile content round-trips byte for byte")

    // A path outside the sandbox must be refused by the server, and the
    // executor must surface that as an error rather than a success.
    do {
        _ = try await executor.readFile(path: "../../../etc/passwd")
        check(false, "path escaping the sandbox is refused")
    } catch {
        check(true, "path escaping the sandbox is refused")
    }
}

func scenarioCompactSurface() async throws {
    let client = makeClient()
    _ = try await client.connect()
    guard let caps = await client.capabilities else {
        return check(false, "capabilities were discovered")
    }

    // This is the user's actual surface: five tools, no write_file, no terminate.
    checkEqual(caps.binding(.startProcess)?.toolName, "start_process", "start_process bound")
    checkEqual(caps.binding(.readFile)?.toolName, "read_file", "read_file bound")
    checkEqual(caps.binding(.applyPatch)?.toolName, "apply_patch", "apply_patch bound")
    check(caps.binding(.writeFile) == nil, "write_file is absent from the compact surface")
    check(caps.emulated.contains(.writeFile), "write_file falls back to shell emulation")
    check(caps.emulated.contains(.terminateProcess), "terminate falls back to shell emulation")
    check(caps.missing.isEmpty, "nothing is left unavailable")

    // Timeout unit inferred from the declared parameter name.
    check(caps.binding(.startProcess)?.timeoutIsMilliseconds == true,
          "timeout_ms recognised as milliseconds")

    let executor = WindowsExecutor(client: client, config: config)

    // Reading still works natively.
    let seedPath = sandbox + "/seed.txt"
    try "seeded\n".write(toFile: seedPath, atomically: true, encoding: .utf8)
    let (seed, _) = try await executor.readFile(path: "seed.txt")
    checkEqual(seed, "seeded\n", "read_file works natively on the compact surface")

    // The write goes through PowerShell emulation. The mock is not Windows, so
    // what is verified is the command the executor EMITS — that it took the
    // fallback, and that the payload is base64 rather than interpolated text.
    // `echo` the emitted command back so it can be inspected.
    let content = "payload with 'quotes' and $vars"
    let expectedBase64 = Data(content.utf8).base64EncodedString()
    let emitted = try await executor.run(
        ExecutionRequest(
            target: .windows,
            command: "cat > /dev/null; echo " + shellQuote(
                WindowsShellEmulation.writeFileCommand(path: "C:\\x.txt",
                                                       contents: Data(content.utf8))),
            timeout: 20
        ),
        onOutput: { _ in }
    )
    checkContains(emitted.output, expectedBase64,
                  "emulated write carries its payload as base64")
    checkContains(emitted.output, "FromBase64String",
                  "emulated write decodes base64 on the remote side")
    check(!emitted.output.contains("$vars\""),
          "raw payload is never interpolated into the command")
}

func scenarioSSE() async throws {
    let client = makeClient()
    _ = try await client.connect()
    let executor = WindowsExecutor(client: client, config: config)

    let streamed = StreamCollector()
    let result = try await executor.run(
        ExecutionRequest(target: .windows, command: "echo sse-path-works", timeout: 20),
        onOutput: { streamed.append($0) }
    )
    checkContains(result.output, "sse-path-works", "result arrives over an SSE body")
    check(streamed.all.contains("working"),
          "progress notifications on the SSE stream reach the caller")
}

func scenarioReconnect() async throws {
    // The server rejects the session on the 5th request. The client should
    // re-handshake transparently and the call should still succeed.
    let client = makeClient()
    _ = try await client.connect()
    let executor = WindowsExecutor(client: client, config: config)

    var succeeded = 0
    for index in 0..<4 {
        let result = try await executor.run(
            ExecutionRequest(target: .windows, command: "echo run-\(index)", timeout: 20),
            onOutput: { _ in }
        )
        if result.output.contains("run-\(index)") { succeeded += 1 }
    }
    checkEqual(succeeded, 4, "every call succeeded despite the session being dropped mid-run")
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - Entry point

// Top-level `await`, not a Task plus a semaphore. Top-level code in main.swift
// is MainActor-isolated, so a `Task {}` here inherits the MainActor and
// blocking the thread on a semaphore deadlocks: the task can never be
// scheduled. This cost an afternoon once; don't reintroduce it.
do {
    switch scenario {
    case "full": try await scenarioFullSurface()
    case "compact": try await scenarioCompactSurface()
    case "sse": try await scenarioSSE()
    case "reconnect": try await scenarioReconnect()
    default:
        check(false, "unknown scenario '\(scenario)'")
    }
} catch {
    check(false, "threw: \(error)")
}

let summary = results.summary
print("  \(summary.passed)/\(summary.total) checks passed")
exit(results.isClean ? 0 : 1)
