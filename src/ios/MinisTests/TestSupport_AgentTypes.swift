import Foundation

// Test-target-only stand-ins for three model-metadata types.
//
// Mirrors TestSupport_AppLogger.swift, and exists for the same reason. The
// MinisTests target compiles a few production sources directly, and the new
// unified-execution / local-inference sources need `AgentProvider.swift` (for
// AgentToolDefinition, AgentMessage, AgentContentPart, sanitizeToolId), which
// is compiled in for real.
//
// AgentProvider.swift in turn references LLMModel, LLMUsage and ThinkingLevel,
// which live in LLMTypes.swift. Pulling that in is not worth it:
//
//   * LLMTypes.swift references ModelsDevAPI, which drags in the models.dev
//     refresh machinery — network, persistence, the provider config store.
//   * The app target builds in Swift 5 language mode; MinisTests builds in
//     Swift 6 with strict concurrency. Several of those files rely on the
//     Swift 5 leniency (ThinkingLevelCatalog's `rules` table, for one) and do
//     not compile under strict checking. Making them compile would mean
//     editing upstream files for a test-only reason, which is exactly the
//     divergence this fork is trying to avoid.
//
// So the three types are stubbed. None of them is exercised by any test here —
// they appear only in signatures the tests don't call — and keeping them
// minimal ensures a test can never accidentally assert against the stub's
// behaviour instead of the app's.

struct LLMUsage {
    let inputTokens: Int
    let outputTokens: Int
}

struct LLMModel: Equatable, Hashable {
    let id: String
    let displayName: String
    let provider: String
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var catalogMaxThinkingLevel: ThinkingLevel { .off }
}

enum ThinkingLevel: String, Comparable {
    case off, low, medium, high

    private var rank: Int {
        switch self {
        case .off: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    static func < (a: ThinkingLevel, b: ThinkingLevel) -> Bool { a.rank < b.rank }
}
