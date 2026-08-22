//
//  LocalProviderRegistration.swift
//  MinisApp
//
//  Puts a downloaded on-device model into the model picker.
//
//  Why this is a separate step
//  --------------------------
//  `AIChatViewModel+ProviderFactory` routes to the on-device provider when a
//  model id begins with `local/` — that prefix is the single source of truth,
//  and it works before any provider instance exists. But the app only ever
//  *offers* models that have a `ModelEntry` in `ProviderConfigStore`, so
//  without this file a user could download Qwen 3.5 and then have no way to
//  select it: the feature would be implemented, compiled, unit-tested, and
//  unreachable.
//
//  Registration is explicit rather than automatic. The seed catalog lists four
//  candidates and most users will want one; adding all four to the picker
//  before anything is downloaded would put three dead rows in front of every
//  model choice for the rest of the app's life.
//

import Foundation

@MainActor
enum LocalProviderRegistration {

    /// Label for the single provider instance that owns every local model.
    static let instanceLabel = "On-device"

    /// The `.local` provider instance, created on first use.
    ///
    /// `credentialType` is `.apiKey` because `ProviderCredential` has only two
    /// cases and `.oauth` would start a sign-in flow that does not exist here.
    /// Nothing reads a key for this type — `ProviderInstance.hasAnyCredential`
    /// returns true for `.local` outright, which is what keeps these models
    /// selectable.
    static func instance() -> ProviderInstance {
        let store = ProviderConfigStore.shared
        if let existing = store.instances.first(where: { $0.providerType == .local }) {
            return existing
        }
        let created = ProviderInstance(
            label: instanceLabel,
            providerType: .local,
            credentialType: .apiKey
        )
        store.addInstance(created)
        return created
    }

    /// True when this model already appears in the picker.
    static func isRegistered(_ entry: LocalModelEntry) -> Bool {
        ProviderConfigStore.shared.instances
            .first(where: { $0.providerType == .local })
            .map { inst in
                ProviderConfigStore.shared.modelEntries.contains {
                    $0.providerInstanceId == inst.id && $0.baseModel.id == entry.appModelID
                }
            } ?? false
    }

    /// Add the model to the picker. Idempotent — `addEntry` deduplicates on
    /// (instance, model id) and returns false for a repeat.
    ///
    /// The entry is `isCustom: true` so `replaceEntries` preserves it: the
    /// refresh path for `.local` returns an empty list (there is no remote
    /// models endpoint to ask), and only custom entries survive that.
    @discardableResult
    static func register(_ entry: LocalModelEntry) -> Bool {
        let inst = instance()
        // `nil`, not `false`. Qwen 3.5 is a hybrid reasoning model and emits
        // <think>…</think>; declaring `false` hid the thinking control for it
        // entirely, which is the "hiding the toggle on a reasoning-capable
        // model makes the feature unreachable" case that
        // AIChatViewModel.currentModelSupportsReasoning documents.
        //
        // `nil` is also the honest answer rather than `true`: the catalog
        // accepts any Hugging Face repo the user types, so the app cannot know
        // whether an arbitrary one reasons. Unknown means the user may opt in,
        // and MLXLocalProvider's think parser passes non-reasoning output
        // through verbatim, so enabling it on a plain model costs nothing.
        let model = LLMModel(
            id: entry.appModelID,
            displayName: entry.displayName,
            provider: instanceLabel,
            contextWindow: entry.contextWindow,
            supportsReasoning: nil
        )
        return ProviderConfigStore.shared.addEntry(
            ModelEntry(providerInstanceId: inst.id, model: model, isCustom: true)
        )
    }

    /// Remove the model from the picker, leaving any downloaded weights alone.
    static func unregister(_ entry: LocalModelEntry) {
        let store = ProviderConfigStore.shared
        guard let inst = store.instances.first(where: { $0.providerType == .local }),
              let existing = store.modelEntries.first(where: {
                  $0.providerInstanceId == inst.id && $0.baseModel.id == entry.appModelID
              })
        else { return }
        store.removeEntry(existing.id)
    }
}
