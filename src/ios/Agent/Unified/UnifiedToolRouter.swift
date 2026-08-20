//
//  UnifiedToolRouter.swift
//  MinisApp
//
//  The seam between the existing agent loop and the remote executor.
//
//  Deliberately thin. Every decision worth testing lives in
//  UnifiedToolRouting (pure) or in WindowsExecutor / DesktopCommanderAdapter
//  (tested against recorded endpoint shapes). This file connects them and owns
//  one piece of state: the per-endpoint client, so the MCP handshake and the
//  endpoint's tool discovery happen once rather than per tool call.
//
//  Integration into AIChatViewModel+ConcurrentTools is one early return per
//  tool case. When a call is local — the overwhelmingly common path — this
//  returns nil immediately and the original implementation runs untouched.
//

import Foundation

/// Result of a tool call that ran on a remote machine.
struct RemoteToolOutcome: Sendable {
    let output: String
    let success: Bool
    let imageData: Data?
    let imageMimeType: String?

    init(output: String, success: Bool, imageData: Data? = nil, imageMimeType: String? = nil) {
        self.output = output
        self.success = success
        self.imageData = imageData
        self.imageMimeType = imageMimeType
    }
}

/// Compact, allow-listed bridge from one model-facing tool to Windows MCP's
/// ten native tools. The model never receives the ten upstream schemas.
enum WindowsControlBridge {
    struct Request: Sendable, Equatable {
        let toolName: String
        let arguments: [String: MCPValue]
    }

    enum Problem: Error, LocalizedError, Equatable {
        case missingTool
        case unsupportedTool(String)
        case invalidArgumentsJSON
        case argumentsMustBeObject

        var errorDescription: String? {
            switch self {
            case .missingTool: return "windows_control needs a `tool`."
            case .unsupportedTool(let tool): return "Unsupported Windows MCP tool `\(tool)`."
            case .invalidArgumentsJSON: return "`arguments_json` must be valid JSON."
            case .argumentsMustBeObject: return "`arguments_json` must encode a JSON object."
            }
        }
    }

    static let toolNames: [String: String] = [
        "app": "App", "powershell": "PowerShell", "filesystem": "FileSystem",
        "snapshot": "Snapshot", "screenshot": "Screenshot", "click": "Click",
        "type": "Type", "scroll": "Scroll", "move": "Move", "shortcut": "Shortcut",
    ]

    static func parse(_ args: [String: Any]) throws -> Request {
        guard let rawTool = args["tool"] as? String,
              !rawTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Problem.missingTool
        }
        let key = rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let toolName = toolNames[key] else { throw Problem.unsupportedTool(rawTool) }
        let rawJSON = ((args["arguments_json"] as? String) ?? "{}")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = (rawJSON.isEmpty ? "{}" : rawJSON).data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            throw Problem.invalidArgumentsJSON
        }
        guard let object = decoded as? [String: Any] else { throw Problem.argumentsMustBeObject }
        return Request(toolName: toolName, arguments: object.mapValues(MCPValue.from))
    }
}

actor UnifiedToolRouter {

    static let shared = UnifiedToolRouter()

    private var clients: [String: MCPHTTPClient] = [:]
    private let secrets = RemoteEndpointStore.Secrets()

    private init() {}

    /// Drop cached clients so the next call re-reads configuration and
    /// re-handshakes. Called when an endpoint is added, edited or removed.
    nonisolated func invalidateClients() {
        Task { await self.clearClients() }
    }

    private func clearClients() {
        clients.removeAll()
    }

    /// Run a tool call remotely, or return nil to let the caller run it locally.
    ///
    /// - Parameters:
    ///   - toolName: canonical tool name.
    ///   - argsJSON: the arguments the agent loop already serialized.
    ///   - onOutput: incremental output, for live display of a long remote run.
    func routeIfRemote(
        toolName: String,
        argsJSON: String,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> RemoteToolOutcome? {
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let endpoint = await MainActor.run { RemoteEndpointStore.shared.activeEndpoint(for: .windows) }
        if toolName == "windows_control" {
            return await routeWindowsControl(args: args, endpoint: endpoint)
        }
        let plan = UnifiedToolRouting.plan(
            toolName: toolName, args: args, remoteAvailable: endpoint != nil)

        switch plan {
        case .local:
            return nil
        case .rejected(let reason):
            // A rejection is a real tool result, not a fall-through to local
            // execution: the model asked for the PC, and running it here
            // instead would have it believe it acted on the PC.
            return RemoteToolOutcome(output: "Error: \(reason)", success: false)
        default:
            break
        }

        guard let endpoint else {
            return RemoteToolOutcome(
                output: "Error: no remote computer is configured.", success: false)
        }

        // Consequential operations on a machine the user isn't looking at get a
        // confirmation. See RemoteCommandRisk for why this is a guardrail
        // against a confused model, not a security boundary.
        let risk = RemoteCommandRisk.classify(plan: plan)
        if risk.needsConfirmation,
           let message = RemoteCommandRisk.confirmationMessage(
               risk: risk, hostLabel: endpoint.hostLabel, detail: Self.planDescription(plan)
           ) {
            if case .denied(let why) = await RemoteActionApproval.shared.request(
                message: message, endpointId: endpoint.id
            ) {
                return RemoteToolOutcome(output: why, success: false)
            }
        }

        do {
            let executor = WindowsExecutor(client: try client(for: endpoint), config: endpoint)
            return try await perform(plan, with: executor, endpoint: endpoint, onOutput: onOutput)
        } catch {
            return RemoteToolOutcome(
                output: failureText(error, endpoint: endpoint), success: false)
        }
    }

    // MARK: Execution

    private func routeWindowsControl(
        args: [String: Any], endpoint: RemoteEndpointConfig?
    ) async -> RemoteToolOutcome {
        guard let endpoint else {
            return RemoteToolOutcome(output: "Error: no remote computer is configured.", success: false)
        }
        do {
            let request = try WindowsControlBridge.parse(args)
            let result = try await client(for: endpoint).callTool(
                name: request.toolName, arguments: request.arguments
            )
            let firstImage = result.images.first
            let imageData = firstImage.flatMap { Data(base64Encoded: $0.base64) }
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = "Windows MCP \(request.toolName) completed on \(endpoint.hostLabel)." }
            else { text = "[Windows MCP \(request.toolName) on \(endpoint.hostLabel)]\n" + text }
            if result.images.count > 1 { text += "\n[\(result.images.count) images returned; first attached]" }
            return RemoteToolOutcome(
                output: text, success: !result.isError,
                imageData: imageData, imageMimeType: firstImage?.mimeType
            )
        } catch {
            return RemoteToolOutcome(output: failureText(error, endpoint: endpoint), success: false)
        }
    }

    private func perform(
        _ plan: RemoteToolPlan,
        with executor: WindowsExecutor,
        endpoint: RemoteEndpointConfig,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> RemoteToolOutcome {
        switch plan {
        case .shell(let command, let timeout, let cwd):
            let result = try await executor.run(
                ExecutionRequest(target: .windows, command: command,
                                 workingDirectory: cwd, timeout: timeout),
                onOutput: onOutput
            )
            return RemoteToolOutcome(
                output: result.modelFacingText(hostLabel: endpoint.hostLabel),
                success: result.state.isSuccess
            )

        case .readFile(let path):
            let (text, truncated) = try await executor.readFile(path: path)
            // The provenance line is what stops the model editing the iPad's
            // copy of a file it just read from the PC.
            var body = "[\(UnifiedPath(scheme: .win, path: path).provenance(windowsHost: endpoint.hostLabel))]\n"
            body += text
            if truncated { body += "\n[output truncated]" }
            return RemoteToolOutcome(output: body, success: true)

        case .writeFile(let path, let content, let append):
            if append {
                // No endpoint verb appends, and read-modify-write would race
                // any process holding the file. A shell redirect is atomic
                // enough and is what the user would do by hand.
                let escaped = WindowsShellEmulation.singleQuoted(path)
                let b64 = Data(content.utf8).base64EncodedString()
                let command = "try { "
                    + "$b = [Convert]::FromBase64String('\(b64)'); "
                    + "$s = [IO.File]::Open(\(escaped), 'Append', 'Write'); "
                    + "$s.Write($b, 0, $b.Length); $s.Close(); \"MINIS_OK\" "
                    + "} catch { \"MINIS_ERR:$($_.Exception.Message)\" }"
                let result = try await executor.run(
                    ExecutionRequest(target: .windows, command: command, timeout: 60),
                    onOutput: { _ in }
                )
                if case .failed(let message) = WindowsShellEmulation.parseOutcome(result.output) {
                    return RemoteToolOutcome(output: "Error: \(message)", success: false)
                }
                return RemoteToolOutcome(
                    output: "Appended \(content.count) characters to win:\(path) on \(endpoint.hostLabel).",
                    success: true)
            }
            try await executor.writeFile(path: path, contents: content)
            return RemoteToolOutcome(
                output: "Wrote \(content.count) characters to win:\(path) on \(endpoint.hostLabel).",
                success: true)

        case .editFile(let path, let old, let new, let all):
            try await executor.applyPatch(path: path, oldString: old, newString: new, replaceAll: all)
            return RemoteToolOutcome(
                output: "Edited win:\(path) on \(endpoint.hostLabel).", success: true)

        case .local, .rejected:
            // Both are handled before this point; reaching here would be a
            // programming error rather than a runtime condition.
            return RemoteToolOutcome(output: "Error: nothing to do.", success: false)
        }
    }

    // MARK: Clients

    private func client(for endpoint: RemoteEndpointConfig) throws -> MCPHTTPClient {
        if let existing = clients[endpoint.id] { return existing }
        guard endpoint.isValid else {
            throw ExecutionTargetUnavailable.notConfigured(endpoint.target)
        }
        let client = MCPHTTPClient(
            config: endpoint,
            secrets: secrets,
            transport: URLSessionStreamTransport(
                session: URLSessionStreamTransport.makeSession(requestTimeout: endpoint.requestTimeout)),
            clientName: "Minis",
            // Identify honestly. Some MCP servers gate behaviour on the client
            // name, and misrepresenting it is the kind of thing that makes a
            // fork unmaintainable.
            clientVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        )
        clients[endpoint.id] = client
        return client
    }

    /// Probe an endpoint for the Settings row.
    func probe(endpoint: RemoteEndpointConfig) async -> RemoteEndpointStore.EndpointHealth {
        do {
            let client = try client(for: endpoint)
            switch await client.probe() {
            case .success(let info):
                let capabilities = await client.capabilities?.summary ?? "no tools discovered"
                return .reachable(summary: info.summary, capabilities: capabilities)
            case .failure(let error):
                return .unreachable(reason: error.localizedDescription)
            }
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    /// What the confirmation prompt shows: the command verbatim for a shell
    /// run, the path and size for a file operation.
    private static func planDescription(_ plan: RemoteToolPlan) -> String {
        switch plan {
        case .shell(let command, _, _):
            return command
        case .writeFile(let path, let content, let append):
            return "\(append ? "Append" : "Write") \(content.count) characters to \(path)"
        case .editFile(let path, let old, _, let all):
            let scope = all ? "every occurrence of " : ""
            return "Replace \(scope)\"\(old.prefix(80))\" in \(path)"
        case .readFile(let path):
            return "Read \(path)"
        case .local, .rejected:
            return ""
        }
    }

    // MARK: Errors

    /// Turn a transport failure into something the model can act on.
    ///
    /// "The PC is asleep" and "you asked for a tool that doesn't exist" call
    /// for completely different next moves, and a generic error message makes
    /// the model retry the wrong one.
    private func failureText(_ error: Error, endpoint: RemoteEndpointConfig) -> String {
        if let mcp = error as? MCPError {
            if mcp.isTransient {
                return "Error: couldn't reach \(endpoint.hostLabel) — \(mcp.localizedDescription). "
                     + "The PC may be asleep or off the network. Don't retry immediately; "
                     + "tell the user and continue with what can be done on the iPad."
            }
            return "Error: \(mcp.localizedDescription)"
        }
        if let unavailable = error as? ExecutionTargetUnavailable {
            return "Error: \(unavailable.localizedDescription)"
        }
        return "Error: \(error.localizedDescription)"
    }
}
