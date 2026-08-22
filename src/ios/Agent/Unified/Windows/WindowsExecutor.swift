//
//  WindowsExecutor.swift
//  MinisApp
//
//  The Windows half of the unified executor.
//
//  Everything here exists to make a command on the PC behave, from the agent
//  loop's point of view, exactly like a command in the iSH sandbox: same
//  request shape, same streaming callback, same terminal states, same cancel
//  path. Where the endpoint can't do something natively, the adapter emulates
//  it over the shell rather than leaking the gap upwards.
//
//  The model never learns any of this. It sees `target: "windows"`.
//

import Foundation

// MARK: - Executor

/// Runs commands on a remote Windows host through its MCP endpoint.
///
/// One instance per configured endpoint. The client it wraps is an actor, so
/// this type carries no mutable state of its own beyond configuration.
struct WindowsExecutor: UnifiedExecutor {

    let target: ExecutionTarget = .windows
    private let client: MCPHTTPClient
    private let config: RemoteEndpointConfig
    /// Cap on how much output a single call returns to the model. A `npm
    /// install` or a full test suite easily produces megabytes; a 4B model's
    /// whole context is smaller than that.
    private let outputLimit: Int

    init(client: MCPHTTPClient, config: RemoteEndpointConfig, outputLimit: Int = 60_000) {
        self.client = client
        self.config = config
        self.outputLimit = outputLimit
    }

    var hostLabel: String { config.hostLabel }

    // MARK: run

    func run(
        _ request: ExecutionRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> ExecutionResult {
        let started = Date()
        try await client.connect()
        guard let caps = await client.capabilities, let start = caps.binding(.startProcess) else {
            throw ExecutionTargetUnavailable.unreachable(
                .windows, detail: "the endpoint exposes no command-execution tool"
            )
        }

        var values: [RemoteArg: MCPValue] = [.command: .string(request.command)]
        if start.name(for: .timeoutMS) != nil {
            values[.timeoutMS] = .int(timeoutValue(request.timeout, binding: start))
        }
        if let cwd = request.workingDirectory ?? config.defaultWorkingDirectory {
            values[.workingDirectory] = .string(cwd)
        }

        let result = try await client.callTool(
            name: start.toolName,
            arguments: start.arguments(values),
            onStreamedText: onOutput
        )
        let handle = WindowsResultParser.processID(from: result).map {
            ExecutionHandle(target: .windows, id: $0)
        }

        if result.isError {
            return ExecutionResult(
                target: .windows, handle: handle,
                state: .failed(message: clip(result.text).text),
                output: "", duration: Date().timeIntervalSince(started)
            )
        }

        // An interactive request returns as soon as the process is up so the
        // model can drive it turn by turn.
        if request.interactive {
            let clipped = clip(result.text)
            return ExecutionResult(
                target: .windows, handle: handle,
                state: handle == nil ? .exited(code: WindowsResultParser.exitCode(from: result) ?? 0) : .running,
                output: clipped.text, truncated: clipped.truncated,
                duration: Date().timeIntervalSince(started)
            )
        }

        // Non-interactive: if the endpoint returned before the process
        // finished, drain it to completion within the caller's budget. Without
        // this a `start_process` with a short internal timeout silently returns
        // a partial log and the model concludes the build passed.
        var combined = result.text
        var state: ExecutionState = .exited(code: WindowsResultParser.exitCode(from: result) ?? 0)
        if let handle, WindowsResultParser.isStillRunning(result) {
            let drained = try await drain(
                handle: handle, caps: caps, deadline: started.addingTimeInterval(request.timeout),
                onOutput: onOutput
            )
            combined += drained.text
            state = drained.state
        }

        let clipped = clip(combined)
        return ExecutionResult(
            target: .windows, handle: handle, state: state,
            output: clipped.text, truncated: clipped.truncated,
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Poll a running process until it exits or the deadline passes.
    ///
    /// Backs off from 250ms to 2s. A tight poll would burn the iPad's battery
    /// and hammer the LAN for a 20-minute build; a fixed slow poll would make
    /// a 300ms command feel sluggish. The ramp gets both.
    private func drain(
        handle: ExecutionHandle,
        caps: RemoteCapabilities,
        deadline: Date,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> (text: String, state: ExecutionState) {
        guard let read = caps.binding(.readProcessOutput) else {
            return ("", .running)
        }
        var text = ""
        var delayMS: UInt64 = 250
        while Date() < deadline {
            if Task.isCancelled { return (text, .cancelled) }
            try await Task.sleep(nanoseconds: delayMS * 1_000_000)
            delayMS = min(delayMS * 2, 2000)

            var values: [RemoteArg: MCPValue] = [.processID: .string(handle.id)]
            if read.name(for: .timeoutMS) != nil {
                values[.timeoutMS] = .int(timeoutValue(5, binding: read))
            }
            let chunk = try await client.callTool(name: read.toolName, arguments: read.arguments(values))
            if !chunk.text.isEmpty {
                text += chunk.text
                onOutput(chunk.text)
            }
            if !WindowsResultParser.isStillRunning(chunk) {
                return (text, .exited(code: WindowsResultParser.exitCode(from: chunk) ?? 0))
            }
            if text.count > outputLimit { break }
        }
        return (text, Date() >= deadline ? .timedOut : .running)
    }

    // MARK: readOutput / interact / cancel

    func readOutput(_ handle: ExecutionHandle, timeout: TimeInterval) async throws -> ExecutionResult {
        try await client.connect()
        guard let caps = await client.capabilities, let read = caps.binding(.readProcessOutput) else {
            throw ExecutionTargetUnavailable.unreachable(
                .windows, detail: "the endpoint can't read output from a running process"
            )
        }
        var values: [RemoteArg: MCPValue] = [.processID: .string(handle.id)]
        if read.name(for: .timeoutMS) != nil {
            values[.timeoutMS] = .int(timeoutValue(timeout, binding: read))
        }
        let result = try await client.callTool(name: read.toolName, arguments: read.arguments(values))
        let clipped = clip(result.text)
        return ExecutionResult(
            target: .windows, handle: handle,
            state: WindowsResultParser.isStillRunning(result)
                ? .running
                : .exited(code: WindowsResultParser.exitCode(from: result) ?? 0),
            output: clipped.text, truncated: clipped.truncated
        )
    }

    func interact(_ handle: ExecutionHandle, input: String, timeout: TimeInterval) async throws -> ExecutionResult {
        try await client.connect()
        guard let caps = await client.capabilities, let interact = caps.binding(.interactWithProcess) else {
            throw ExecutionTargetUnavailable.unreachable(
                .windows, detail: "the endpoint doesn't support interactive processes"
            )
        }
        var values: [RemoteArg: MCPValue] = [
            .processID: .string(handle.id),
            .input: .string(input),
        ]
        if interact.name(for: .timeoutMS) != nil {
            values[.timeoutMS] = .int(timeoutValue(timeout, binding: interact))
        }
        let result = try await client.callTool(name: interact.toolName, arguments: interact.arguments(values))
        let clipped = clip(result.text)
        return ExecutionResult(
            target: .windows, handle: handle,
            state: result.isError
                ? .failed(message: clipped.text)
                : (WindowsResultParser.isStillRunning(result) ? .running
                   : .exited(code: WindowsResultParser.exitCode(from: result) ?? 0)),
            output: clipped.text, truncated: clipped.truncated
        )
    }

    func cancel(_ handle: ExecutionHandle) async throws {
        try await client.connect()
        guard let caps = await client.capabilities else { return }
        // Try the native verb, then the shell. A failure in the first is not
        // fatal — falling through is the whole point — but a failure in both
        // leaves a live process on the user's machine, so it is thrown rather
        // than swallowed. Callers that genuinely don't care use `try?`.
        //
        // Deliberately no logging here: this type has no app dependencies,
        // which is what lets it be exercised by the off-device harness and the
        // integration driver. Reporting is the caller's job.
        var lastError: Error?

        if let terminate = caps.binding(.terminateProcess) {
            do {
                _ = try await client.callTool(
                    name: terminate.toolName,
                    arguments: terminate.arguments([.processID: .string(handle.id)])
                )
                return
            } catch {
                lastError = error
            }
        }

        if let start = caps.binding(.startProcess) {
            do {
                _ = try await client.callTool(
                    name: start.toolName,
                    arguments: start.arguments([
                        .command: .string(WindowsShellEmulation.terminateCommand(pid: handle.id))
                    ])
                )
                return
            } catch {
                lastError = error
            }
        }

        if let lastError { throw lastError }
    }

    // MARK: File operations

    /// Read a remote file. Uses the native tool when present, otherwise a
    /// base64 shell read so binary-safe content survives the round trip.
    func readFile(path: String, maxBytes: Int = 200_000) async throws -> (text: String, truncated: Bool) {
        try await client.connect()
        guard let caps = await client.capabilities else { throw MCPError.notInitialized }

        if let read = caps.binding(.readFile) {
            let result = try await client.callTool(
                name: read.toolName,
                arguments: read.arguments([.path: .string(path)])
            )
            if result.isError { throw MCPError.rpc(code: 0, message: result.text) }
            let clipped = clip(result.text, limit: maxBytes)
            return (clipped.text, clipped.truncated)
        }

        guard let start = caps.binding(.startProcess) else {
            throw ExecutionTargetUnavailable.unreachable(.windows, detail: "no file-read capability")
        }
        let result = try await client.callTool(
            name: start.toolName,
            arguments: start.arguments([.command: .string(WindowsShellEmulation.readFileCommand(path: path))])
        )
        switch WindowsShellEmulation.parseOutcome(result.text) {
        case .failed(let message):
            throw MCPError.rpc(code: 0, message: message)
        case .ok(let detail):
            let base64 = detail.isEmpty ? result.text.trimmingCharacters(in: .whitespacesAndNewlines) : detail
            guard let data = Data(base64Encoded: base64.filter { !$0.isWhitespace }),
                  let text = String(data: data, encoding: .utf8) else {
                throw MCPError.rpc(code: 0, message: "file is not UTF-8 text")
            }
            let clipped = clip(text, limit: maxBytes)
            return (clipped.text, clipped.truncated)
        }
    }

    /// Write a remote file wholesale.
    func writeFile(path: String, contents: String) async throws {
        try await client.connect()
        guard let caps = await client.capabilities else { throw MCPError.notInitialized }

        if let write = caps.binding(.writeFile) {
            let result = try await client.callTool(
                name: write.toolName,
                arguments: write.arguments([.path: .string(path), .content: .string(contents)])
            )
            if result.isError { throw MCPError.rpc(code: 0, message: result.text) }
            return
        }
        guard let start = caps.binding(.startProcess) else {
            throw ExecutionTargetUnavailable.unreachable(.windows, detail: "no file-write capability")
        }
        let command = WindowsShellEmulation.writeFileCommand(path: path, contents: Data(contents.utf8))
        let result = try await client.callTool(
            name: start.toolName,
            arguments: start.arguments([.command: .string(command)])
        )
        if case .failed(let message) = WindowsShellEmulation.parseOutcome(result.text) {
            throw MCPError.rpc(code: 0, message: message)
        }
    }

    /// Targeted edit of a remote file.
    func applyPatch(path: String, oldString: String, newString: String, replaceAll: Bool) async throws {
        guard !oldString.isEmpty else {
            throw MCPError.rpc(code: 0, message: "old_string must not be empty")
        }
        try await client.connect()
        guard let caps = await client.capabilities else { throw MCPError.notInitialized }

        // Native replace-all is only safe when the endpoint explicitly exposes that semantic.
        if let patch = caps.binding(.applyPatch),
           !replaceAll || patch.name(for: .replaceAll) != nil {
            var values: [RemoteArg: MCPValue] = [
                .path: .string(path),
                .oldString: .string(oldString),
                .newString: .string(newString),
            ]
            if patch.name(for: .replaceAll) != nil { values[.replaceAll] = .bool(replaceAll) }
            let result = try await client.callTool(name: patch.toolName, arguments: patch.arguments(values))
            if result.isError { throw MCPError.rpc(code: 0, message: result.text) }
            return
        }
        guard let start = caps.binding(.startProcess),
              let command = WindowsShellEmulation.applyPatchCommand(
                path: path, oldString: oldString, newString: newString, replaceAll: replaceAll)
        else {
            throw ExecutionTargetUnavailable.unreachable(.windows, detail: "no file-edit capability")
        }
        let result = try await client.callTool(
            name: start.toolName,
            arguments: start.arguments([.command: .string(command)])
        )
        if case .failed(let message) = WindowsShellEmulation.parseOutcome(result.text) {
            throw MCPError.rpc(code: 0, message: message)
        }
    }

    // MARK: Helpers

    private func timeoutValue(_ seconds: TimeInterval, binding: RemoteToolBinding) -> Int {
        binding.timeoutIsMilliseconds ? Int(seconds * 1000) : Int(seconds)
    }

    private func clip(_ text: String, limit: Int? = nil) -> (text: String, truncated: Bool) {
        OutputClipper.clip(text, limit: limit ?? outputLimit)
    }
}
