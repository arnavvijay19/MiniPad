//
//  UnifiedAgentSettingsView.swift
//  MinisApp
//
//  Settings for the three capabilities this fork adds: on-device models, the
//  remote computer, and registered Shortcuts.
//
//  Deliberately follows MCPIntegrationsView's shape — a plain `List` of rows
//  with a status dot, a detail sheet behind each row, and swipe-to-delete —
//  because those three things are the same *kind* of thing to a user
//  (integrations they configure once) and should not each invent their own
//  layout. No gradients, no dashboards; the app's existing design language.
//

import SwiftUI

struct UnifiedAgentSettingsView: View {

    @ObservedObject private var models = LocalModelStore.shared
    @ObservedObject private var endpoints = RemoteEndpointStore.shared
    @ObservedObject private var shortcuts = ShortcutRegistryStore.shared

    @State private var editingEndpoint: RemoteEndpointConfig?
    @State private var addingEndpoint = false
    @State private var editingShortcut: ShortcutDescriptor?
    @State private var addingShortcut = false
    @State private var addingModelRepo = ""
    @State private var addModelError: String?
    /// Repo ids that already have a ModelEntry, so the row can say so.
    /// Recomputed on appear and after each change rather than derived in the
    /// body — `ProviderConfigStore` is not observed here, and reading it every
    /// body evaluation would walk every entry on every keystroke.
    @State private var registered: Set<String> = []
    @State private var isRefreshing = false

    var body: some View {
        List {
            localModelsSection
            remoteComputerSection
            shortcutsSection
            diagnosticsSection
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshRegistered()
            // Compatibility verdicts are N network round trips, so they are
            // fetched when this screen opens rather than at launch.
            guard models.compatibility.isEmpty else { return }
            await models.refreshCompatibility()
        }
        .sheet(item: $editingEndpoint) { RemoteEndpointFormView(endpoint: $0) }
        .sheet(isPresented: $addingEndpoint) { RemoteEndpointFormView(endpoint: nil) }
        .sheet(item: $editingShortcut) { ShortcutFormView(shortcut: $0) }
        .sheet(isPresented: $addingShortcut) { ShortcutFormView(shortcut: nil) }
    }

    // MARK: - Diagnostics

    /// Two facts that decide whether anything else on this screen can work,
    /// visible without attaching a debugger.
    ///
    /// The container line matters most on a build signed with a free Apple ID:
    /// there is no App Group, so the workspace lives in the app's own sandbox
    /// and the Files-app integration is absent. That is expected, and a user
    /// looking for their files deserves to be told where they are rather than
    /// left to infer it. See
    /// docs/design/unified-agent/FREE_DEVELOPER_CAPABILITIES.md.
    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            LabeledContent("On-device inference") {
                Text(LocalInferenceAvailability.isAvailable ? "available" : "unavailable")
                    .foregroundStyle(LocalInferenceAvailability.isAvailable ? .secondary : .red)
            }
            LabeledContent("Workspace storage") {
                Text(AppGroupContainer.isShared ? "shared container" : "app sandbox")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            if !AppGroupContainer.isShared {
                Text("This build was signed without the App Group entitlement, "
                     + "so the workspace is private to the app and does not appear "
                     + "in the Files app. Everything else — models, terminal, "
                     + "skills, memory, the Windows target — is unaffected.")
            }
        }
    }

    // MARK: - On-device models

    @ViewBuilder
    private var localModelsSection: some View {
        Section {
            if let reason = LocalInferenceAvailability.unavailableReason {
                // Never silently hide the feature: a user who expected offline
                // models needs to know why they aren't there.
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(models.models) { model in
                modelRow(model)
            }
            HStack {
                TextField("Add a Hugging Face repo (owner/name)", text: $addingModelRepo)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { addModel() }
                    .disabled(addingModelRepo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addModelError {
                Text(addModelError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("On-device models")
        } footer: {
            let used = ByteCountFormatter.string(
                fromByteCount: models.totalDiskBytes, countStyle: .file)
            Text("Downloaded models use \(used). Models run entirely on this device — no network, no account.")
        }
    }

    private func refreshRegistered() {
        // Explicit closure rather than passing the method as a value: it is
        // @MainActor, and handing a MainActor function to a nonisolated
        // parameter is the kind of thing Swift 5 tolerates and Swift 6 does
        // not. Calling it here, inside a MainActor method, is unambiguous.
        registered = Set(models.models
            .filter { LocalProviderRegistration.isRegistered($0) }
            .map { $0.repoID })
    }

    @ViewBuilder
    private func modelRow(_ model: LocalModelEntry) -> some View {
        let verdict = models.compatibility[model.repoID]
        let state = models.states[model.repoID] ?? .notDownloaded

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor(state: state, verdict: verdict))
                    .frame(width: 8, height: 8)
                Text(model.displayName)
                Spacer()
                if let size = model.downloadSizeText {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
                // The action that makes the whole feature reachable: until a
                // model has a ModelEntry, nothing in the app can offer it. The
                // weights download on first use, so this is safe to tap before
                // anything has been fetched.
                if registered.contains(model.repoID) {
                    Label("In picker", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .accessibilityLabel("In the model picker")
                } else if verdict?.isSupported != false {
                    Button("Use") {
                        LocalProviderRegistration.register(model)
                        refreshRegistered()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            // The verdict is the point of the row: it says whether this model
            // can run here at all, BEFORE gigabytes are spent finding out.
            if let verdict, !verdict.isSupported {
                Text(verdict.explanation).font(.caption).foregroundStyle(.orange)
            }
            if case .downloading(let fraction) = state {
                ProgressView(value: fraction)
            }
        }
        .swipeActions {
            if !model.isBuiltIn {
                Button("Remove", role: .destructive) {
                    LocalProviderRegistration.unregister(model)
                    models.removeModel(repoID: model.repoID)
                    refreshRegistered()
                }
            }
            if models.isDownloaded(model.repoID) {
                Button("Delete files") { try? models.deleteDownload(repoID: model.repoID) }
                    .tint(.orange)
            }
        }
    }

    private func statusColor(state: LocalModelStore.State,
                             verdict: LocalModelCompatibility?) -> Color {
        if let verdict, !verdict.isSupported { return .orange }
        switch state {
        case .loaded: return .green
        case .downloaded: return .blue
        case .downloading: return .yellow
        case .failed: return .red
        case .notDownloaded: return .secondary
        }
    }

    private func addModel() {
        let repo = addingModelRepo
        addModelError = nil
        Task {
            do {
                try await models.addModel(repoID: repo)
                addingModelRepo = ""
            } catch {
                addModelError = error.localizedDescription
            }
        }
    }

    // MARK: - Remote computer

    @ViewBuilder
    private var remoteComputerSection: some View {
        Section {
            ForEach(endpoints.endpoints) { endpoint in
                Button { editingEndpoint = endpoint } label: { endpointRow(endpoint) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Remove", role: .destructive) { endpoints.remove(id: endpoint.id) }
                    }
            }
            Button("Add a computer") { addingEndpoint = true }
        } header: {
            Text("Remote computer")
        } footer: {
            Text("Lets the agent run commands and edit files on your PC. Files do not sync between machines — the agent copies them explicitly when asked.")
        }
    }

    @ViewBuilder
    private func endpointRow(_ endpoint: RemoteEndpointConfig) -> some View {
        let health = endpoints.health[endpoint.id] ?? .unknown
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(healthColor(health)).frame(width: 8, height: 8)
                Text(endpoint.displayName)
                Spacer()
                if !endpoint.enabled {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Redacted: query strings on tunnel URLs carry tokens.
            Text(endpoint.redactedURL).font(.caption).foregroundStyle(.secondary)
            switch health {
            case .reachable(let summary, let capabilities):
                Text(summary).font(.caption2).foregroundStyle(.secondary)
                Text(capabilities).font(.caption2).foregroundStyle(.secondary)
            case .unreachable(let reason):
                Text(reason).font(.caption2).foregroundStyle(.red)
            case .checking:
                Text("Checking…").font(.caption2).foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }
        }
    }

    private func healthColor(_ health: RemoteEndpointStore.EndpointHealth) -> Color {
        switch health {
        case .reachable: return .green
        case .unreachable: return .red
        case .checking: return .yellow
        case .unknown: return .secondary
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var shortcutsSection: some View {
        Section {
            ForEach(shortcuts.shortcuts) { shortcut in
                Button { editingShortcut = shortcut } label: {
                    HStack {
                        Circle()
                            .fill(shortcut.enabled ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.name)
                            if !shortcut.summary.isEmpty {
                                Text(shortcut.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Remove", role: .destructive) { shortcuts.remove(name: shortcut.name) }
                }
            }
            Button("Add a shortcut") { addingShortcut = true }
        } header: {
            Text("Shortcuts")
        } footer: {
            // The honest explanation for why this list is manual. Without it the
            // screen looks like a missing feature rather than a platform limit.
            Text("iOS gives apps no way to list your shortcuts, so the agent can only run ones you add here. The name must match the shortcut exactly.")
        }
    }
}

// MARK: - Endpoint form

struct RemoteEndpointFormView: View {

    let endpoint: RemoteEndpointConfig?

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var urlString = ""
    @State private var usesBearerToken = false
    @State private var token = ""
    @State private var workingDirectory = ""
    @State private var probeResult: String?
    @State private var isProbing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $displayName)
                    TextField("http://192.168.1.10:8766/mcp", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if let problem = validationProblem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text("The MCP endpoint of your Desktop Commander server. Plain http is allowed to a private or local address; anything on the public internet must use https.")
                }

                Section("Authentication") {
                    Toggle("Bearer token", isOn: $usesBearerToken)
                    if usesBearerToken {
                        SecureField("Token", text: $token)
                            .textInputAutocapitalization(.never)
                    }
                }

                Section {
                    TextField("C:\\Users\\me\\projects", text: $workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Default working directory")
                } footer: {
                    Text("Optional. Commands start here unless the agent says otherwise.")
                }

                Section {
                    Button(isProbing ? "Testing…" : "Test connection") { probe() }
                        .disabled(isProbing || validationProblem != nil)
                    if let probeResult {
                        Text(probeResult).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(endpoint == nil ? "Add computer" : "Edit computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(validationProblem != nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var draft: RemoteEndpointConfig {
        RemoteEndpointConfig(
            id: endpoint?.id ?? UUID().uuidString,
            displayName: displayName.isEmpty ? "Computer" : displayName,
            urlString: urlString,
            usesBearerToken: usesBearerToken,
            headers: endpoint?.headers ?? [:],
            defaultWorkingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            enabled: endpoint?.enabled ?? true
        )
    }

    private var validationProblem: String? {
        draft.validate()?.localizedDescription
    }

    private func load() {
        guard let endpoint else { return }
        displayName = endpoint.displayName
        urlString = endpoint.urlString
        usesBearerToken = endpoint.usesBearerToken
        workingDirectory = endpoint.defaultWorkingDirectory ?? ""
    }

    private func save() {
        RemoteEndpointStore.shared.upsert(draft, bearerToken: usesBearerToken ? token : "")
        dismiss()
    }

    private func probe() {
        isProbing = true
        probeResult = nil
        let config = draft
        Task {
            let health = await UnifiedToolRouter.shared.probe(endpoint: config)
            RemoteEndpointStore.shared.setHealth(health, id: config.id)
            switch health {
            case .reachable(let summary, let capabilities):
                probeResult = "\(summary)\n\(capabilities)"
            case .unreachable(let reason):
                probeResult = reason
            case .checking, .unknown:
                probeResult = nil
            }
            isProbing = false
        }
    }
}

// MARK: - Shortcut form

struct ShortcutFormView: View {

    let shortcut: ShortcutDescriptor?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var inputKind: ShortcutDescriptor.InputKind = .none
    @State private var returnsOutput = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exact shortcut name", text: $name)
                    TextField("What it does", text: $summary, axis: .vertical)
                } header: {
                    Text("Shortcut")
                } footer: {
                    Text("The description is what the agent reads to decide when to use it, so it is worth writing well.")
                }

                Section("Input") {
                    Picker("Takes", selection: $inputKind) {
                        Text("No input").tag(ShortcutDescriptor.InputKind.none)
                        Text("Text").tag(ShortcutDescriptor.InputKind.text)
                        Text("URL or file path").tag(ShortcutDescriptor.InputKind.url)
                    }
                }

                Section {
                    Toggle("Returns a result", isOn: $returnsOutput)
                } footer: {
                    Text("Only shortcuts ending in a 'Stop and Output' step can return anything to the agent.")
                }
            }
            .navigationTitle(shortcut == nil ? "Add shortcut" : "Edit shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let shortcut else { return }
                name = shortcut.name
                summary = shortcut.summary
                inputKind = shortcut.inputKind
                returnsOutput = shortcut.returnsOutput
            }
        }
    }

    private func save() {
        ShortcutRegistryStore.shared.upsert(ShortcutDescriptor(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary,
            inputKind: inputKind,
            returnsOutput: returnsOutput,
            enabled: shortcut?.enabled ?? true
        ))
        dismiss()
    }
}

// MARK: - Approval prompt

/// The confirmation sheet for a destructive remote action.
///
/// Attach once, high in the view hierarchy, so it can surface over whatever the
/// user is looking at when a tool call needs an answer.
struct RemoteActionApprovalModifier: ViewModifier {

    @ObservedObject private var approval = RemoteActionApproval.shared

    func body(content: Content) -> some View {
        content.alert(
            "Run on your PC?",
            isPresented: .constant(approval.pending != nil),
            presenting: approval.pending
        ) { request in
            Button("Run", role: .destructive) { approval.approve(request, remember: false) }
            Button("Always allow this computer") { approval.approve(request, remember: true) }
            Button("Don't run", role: .cancel) { approval.deny(request) }
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    func remoteActionApprovalPrompt() -> some View {
        modifier(RemoteActionApprovalModifier())
    }
}
