//
//  AppGroupContainer.swift
//  MinisApp
//
//  Resolves the container that holds the agent's durable state — the shared
//  workspace, skills and memory — and keeps working when the App Group
//  entitlement was never granted.
//
//  Why this exists
//  ---------------
//  `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns
//  `nil` unless the running binary is signed with a provisioning profile that
//  carries `com.apple.security.application-groups`. Apple issues that only for
//  an App Group registered in Certificates, Identifiers & Profiles, and that
//  portal is a paid-membership feature — so a build signed with a free Apple ID
//  gets `nil` here, always.
//
//  Before this type, the workspace root force-unwrapped that call, so a
//  free-provisioned build did not degrade: it crashed on launch, before the
//  first screen. Everything the user actually wants from this app — local
//  inference, the terminal, files, skills, memory, the Windows executor — needs
//  no App Group whatsoever. Only the extensions do.
//
//  So the container is resolved once, with a fallback inside the app's own
//  sandbox, and the rest of the app asks for `AppGroupContainer.root` without
//  caring which one it got.
//
//  What the fallback deliberately does NOT do
//  ------------------------------------------
//  It does not pretend to be shared. An app extension that falls back lands in
//  *its own* sandbox, not the app's, so the two would silently diverge — which
//  is worse than failing. Extensions therefore keep using
//  `sharedContainer` directly and do nothing when it is absent, and a build
//  without App Groups ships no extensions at all (see
//  docs/design/unified-agent/FREE_DEVELOPER_CAPABILITIES.md).
//

import Foundation

enum AppGroupContainer {

    /// The real App Group container, or `nil` when this binary was not signed
    /// with the entitlement. Extensions must use this, never `root`.
    static let sharedContainer: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
    )

    /// True when the running binary can actually share files with its
    /// extensions. False in any free-provisioned build.
    static var isShared: Bool { sharedContainer != nil }

    /// Where durable agent state lives. The App Group container when there is
    /// one, otherwise a directory in the app's own sandbox with the same
    /// layout, so every path derived from it is unchanged.
    static let root: URL = {
        if let shared = sharedContainer { return shared }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fallback = base.appendingPathComponent("AppGroupFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    /// One line for the launch log, so "where did my files go" is answerable
    /// from a device log without a debugger attached. Named `summary` rather
    /// than `description` to avoid any ambiguity with the metatype at the call
    /// site.
    static var summary: String {
        isShared
            ? "App Group container: \(root.path)"
            : "App Group unavailable (not entitled) — using sandbox fallback: \(root.path)"
    }
}
