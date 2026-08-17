//
//  AIChatViewModel+UnifiedCapabilities.swift
//  MinisApp
//
//  The system-prompt fragments for the capabilities this fork adds.
//
//  Kept in its own file rather than inline in AIChatViewModel so the upstream
//  diff stays to a single call at each assembly site. Both fragments are
//  conditional — a user with no remote computer and no registered shortcuts
//  pays nothing for either, which matters when the model has 32K of context.
//
//  Measured cost when present (real Qwen 3.5 tokenizer,
//  scripts/measure_tool_context.sh):
//
//      <execution_targets>        147 tokens
//      <shortcuts>, 2 registered  104 tokens
//

import Foundation

extension AIChatViewModel {

    /// Capability fragments to append to the system prompt. Returns "" when
    /// neither capability is configured.
    @MainActor
    static func unifiedCapabilityFragments() -> String {
        var out = ""

        if RemoteEndpointStore.shared.hasActiveRemote {
            out += "\n\n" + UnifiedWorkspaceNamespace.promptFragment(
                windowsHost: RemoteEndpointStore.shared.windowsHostLabel)
        }

        if let shortcuts = ShortcutRegistry.promptFragment(ShortcutRegistryStore.shared.shortcuts) {
            out += "\n\n" + shortcuts
        }

        return out
    }
}

// MARK: - Shortcut registry storage

/// Persistence for the user's registered shortcuts.
///
/// iOS gives third-party apps no way to enumerate a user's shortcuts, so this
/// list is the honest and complete answer to "what can you run?" — see
/// ShortcutsBridge for why nothing is inferred.
@MainActor
final class ShortcutRegistryStore: ObservableObject {

    static let shared = ShortcutRegistryStore()

    @Published private(set) var shortcuts: [ShortcutDescriptor] = []

    private static let defaultsKey = "unifiedAgent.shortcuts"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        do {
            shortcuts = try JSONDecoder().decode([ShortcutDescriptor].self, from: data)
        } catch {
            // Don't wipe the user's list on a decode failure — leave it empty
            // for this launch and keep the stored blob until they edit it.
            AppLogger(category: "Shortcuts").error(
                "Could not decode registered shortcuts: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(shortcuts), forKey: Self.defaultsKey)
        } catch {
            AppLogger(category: "Shortcuts").error(
                "Could not persist registered shortcuts: \(error.localizedDescription)")
        }
    }

    func upsert(_ shortcut: ShortcutDescriptor) {
        if let index = shortcuts.firstIndex(where: { $0.name == shortcut.name }) {
            shortcuts[index] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        shortcuts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func remove(name: String) {
        shortcuts.removeAll { $0.name == name }
        save()
    }

    func setEnabled(_ enabled: Bool, name: String) {
        guard let index = shortcuts.firstIndex(where: { $0.name == name }) else { return }
        shortcuts[index].enabled = enabled
        save()
    }

    func find(_ name: String) -> ShortcutDescriptor? {
        ShortcutRegistry.find(name, in: shortcuts)
    }
}
