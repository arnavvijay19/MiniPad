//
//  LocalModelLifecycle.swift
//  MinisApp
//
//  Keeping a multi-gigabyte model resident without getting the app killed.
//
//  A loaded 4-bit model is 3–6 GB of the app's memory budget. iOS does not ask
//  politely before jetsamming a process that overruns; the memory warning is
//  the only notice there is, and an app that ignores it is killed mid-sentence,
//  losing the user's conversation state.
//
//  So this file does three things, in escalating order of disruption:
//
//    1. On a memory warning, drop MLX's buffer cache. Cheap, invisible, often
//       enough — the allocator holds freed buffers that read to the OS as live
//       usage.
//    2. If warnings keep coming, unload the model entirely. The next request
//       reloads it, costing seconds; being killed costs the session.
//    3. On backgrounding, unload proactively. A backgrounded app holding 6 GB
//       is the first thing the OS reclaims, and reloading on return is far
//       cheaper than being terminated.
//
//  Registered once from the app delegate. Compiled unconditionally; the calls
//  into the runtime are gated inside `LocalModelRuntimeControl`.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class LocalModelLifecycle {

    static let shared = LocalModelLifecycle()

    /// Memory warnings seen since the last successful load.
    ///
    /// The first one clears caches; a second within the same load means caches
    /// weren't the problem and the model itself has to go. Counting rather than
    /// unloading immediately avoids throwing away a 20-second load because an
    /// unrelated photo picker briefly spiked.
    private var warningsSinceLoad = 0
    private var observersInstalled = false

    private let log = AppLogger(category: "LocalModel")

    private init() {}

    /// Install the notification observers. Idempotent.
    func start() {
        guard !observersInstalled else { return }
        observersInstalled = true
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMemoryWarning() }
        }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBackgrounded() }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleForegrounded() }
        }
        #endif
    }

    /// Reset the escalation counter after a successful load.
    func noteModelLoaded() {
        warningsSinceLoad = 0
    }

    // MARK: - Handlers

    private func handleMemoryWarning() {
        guard LocalModelRuntimeControl.isModelLoaded else { return }
        warningsSinceLoad += 1

        if warningsSinceLoad == 1 {
            log.warning("[Memory] warning #1 with a model resident — clearing MLX buffer cache")
            LocalModelRuntimeControl.clearCache()
            return
        }

        log.warning("[Memory] warning #\(self.warningsSinceLoad) — unloading the model to avoid a jetsam kill")
        LocalModelRuntimeControl.unload()
        LocalModelStore.shared.setState(.downloaded, repoID: LocalModelStore.shared.loadedRepoID ?? "")
        warningsSinceLoad = 0
    }

    private func handleBackgrounded() {
        guard LocalModelRuntimeControl.isModelLoaded else { return }
        // A backgrounded app holding several GB is the first candidate for
        // reclamation, and being terminated loses more than a reload costs.
        let repoID = LocalModelStore.shared.loadedRepoID
        log.info("[Memory] backgrounded with a model resident — unloading")
        LocalModelRuntimeControl.unload()
        if let repoID { LocalModelStore.shared.setState(.downloaded, repoID: repoID) }
    }

    private func handleForegrounded() {
        warningsSinceLoad = 0
        // Shortcut runs that were abandoned while we were away resolve here;
        // their per-run timers don't fire reliably across a suspension.
        Task { await ShortcutRunCoordinator.shared.sweepExpired() }
    }
}

/// Ungated access to the MLX runtime's lifecycle.
///
/// `LocalModelRuntime` lives behind the compile gate, so nothing outside it can
/// name the type. Everything here is a no-op in a build without the package,
/// which is exactly right: there is no model to unload.
enum LocalModelRuntimeControl {

    static var isModelLoaded: Bool {
        #if MINIS_LOCAL_INFERENCE
        return MainActor.assumeIsolated { LocalModelStore.shared.loadedRepoID != nil }
        #else
        return false
        #endif
    }

    static func unload() {
        #if MINIS_LOCAL_INFERENCE
        Task { await LocalModelRuntime.shared.unload() }
        #endif
    }

    static func clearCache() {
        #if MINIS_LOCAL_INFERENCE
        Task { await LocalModelRuntime.shared.clearBufferCache() }
        #endif
    }
}
