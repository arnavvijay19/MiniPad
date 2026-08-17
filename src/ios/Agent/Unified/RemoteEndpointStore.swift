//
//  RemoteEndpointStore.swift
//  MinisApp
//
//  Persistence and lifecycle for configured remote computers.
//
//  Split from RemoteEndpointConfig (which is pure and testable) because this
//  half touches UserDefaults, the Keychain and the app's environment-variable
//  store. It reuses the app's existing helpers rather than inventing storage:
//  `ProviderKeychainHelper` for the bearer token, `EnvVarStore` for `$$VAR`
//  resolution — the same convention MCPStore already uses for server headers.
//
//  The endpoint URL lives in UserDefaults. It is not a secret, and keeping it
//  next to the app's other settings means it participates in the normal
//  settings lifecycle. The token never goes there, never into a log, and never
//  into a synced record.
//

import Foundation

@MainActor
final class RemoteEndpointStore: ObservableObject {

    static let shared = RemoteEndpointStore()

    @Published private(set) var endpoints: [RemoteEndpointConfig] = []

    /// Last known reachability per endpoint id, for the Settings row. Not
    /// persisted: a stale "connected" badge from three days ago is worse than
    /// no badge, because it makes an unreachable PC look available.
    @Published private(set) var health: [String: EndpointHealth] = [:]

    enum EndpointHealth: Equatable {
        case unknown
        case checking
        case reachable(summary: String, capabilities: String)
        case unreachable(reason: String)
    }

    private static let defaultsKey = "unifiedAgent.remoteEndpoints"
    private static let keychainAccount = "remote-endpoint-token"

    private init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        do {
            endpoints = try JSONDecoder().decode([RemoteEndpointConfig].self, from: data)
        } catch {
            // A decode failure must not wipe the user's configuration on the
            // next save. Log and leave the list empty for this launch; the
            // stored blob is untouched until the user edits something.
            AppLogger(category: "RemoteEndpoint").error(
                "Could not decode stored endpoints: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(endpoints), forKey: Self.defaultsKey)
        } catch {
            AppLogger(category: "RemoteEndpoint").error(
                "Could not persist endpoints: \(error.localizedDescription)")
        }
    }

    // MARK: CRUD

    /// Add or replace an endpoint. The token is stored separately, in the
    /// Keychain, and is never part of the persisted config.
    func upsert(_ endpoint: RemoteEndpointConfig, bearerToken: String? = nil) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        if let bearerToken {
            if bearerToken.isEmpty {
                ProviderKeychainHelper.deleteOAuthString(
                    instanceId: endpoint.id, account: Self.keychainAccount)
            } else {
                ProviderKeychainHelper.saveOAuthString(
                    bearerToken, instanceId: endpoint.id, account: Self.keychainAccount)
            }
        }
        save()
        health[endpoint.id] = .unknown
        UnifiedToolRouter.shared.invalidateClients()
    }

    func remove(id: String) {
        endpoints.removeAll { $0.id == id }
        ProviderKeychainHelper.deleteOAuthString(instanceId: id, account: Self.keychainAccount)
        health.removeValue(forKey: id)
        save()
        UnifiedToolRouter.shared.invalidateClients()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = endpoints.firstIndex(where: { $0.id == id }) else { return }
        endpoints[index].enabled = enabled
        save()
        UnifiedToolRouter.shared.invalidateClients()
    }

    // MARK: Lookup

    /// The endpoint serving a target, if any is enabled and valid.
    func activeEndpoint(for target: ExecutionTarget) -> RemoteEndpointConfig? {
        endpoints.first { $0.enabled && $0.target == target && $0.isValid }
    }

    /// Whether the agent should be told a remote computer exists.
    ///
    /// Gates both the `target` tool parameter and the `<execution_targets>`
    /// prompt fragment, so a user with no PC configured pays nothing for the
    /// capability — measured at 323 Qwen tokens.
    var hasActiveRemote: Bool { activeEndpoint(for: .windows) != nil }

    var windowsHostLabel: String? { activeEndpoint(for: .windows)?.hostLabel }

    func setHealth(_ value: EndpointHealth, id: String) {
        health[id] = value
    }

    // MARK: Secrets

    /// Secret resolution for the transport. A struct rather than a closure so
    /// it can cross the actor boundary into MCPHTTPClient.
    struct Secrets: RemoteEndpointSecretStore {
        func bearerToken(endpointId: String) -> String? {
            ProviderKeychainHelper.loadOAuthString(
                instanceId: endpointId, account: RemoteEndpointStore.keychainAccount)
        }

        func environmentValue(_ name: String) -> String? {
            // Same `$$VAR` convention MCPStore uses for server headers, so a
            // user configures a token once and references it from both.
            MainActor.assumeIsolated { EnvVarStore.shared.value(forKey: name) }
        }
    }
}
