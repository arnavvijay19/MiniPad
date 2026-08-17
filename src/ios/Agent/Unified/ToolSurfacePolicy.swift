//
//  ToolSurfacePolicy.swift
//  MinisApp
//
//  Deciding which tool schemas a given model carries in every request.
//
//  THIS FILE EXISTS BECAUSE OF A MEASUREMENT, NOT A HUNCH
//
//  Tokenizing Minis' actual tool definitions with the actual tokenizers of the
//  target models (scripts/measure_tool_context.py) gives:
//
//      tool             chars    Qwen 3.5    Gemma 4 E2B
//      browser_use       7355        1632           1720
//      shell_execute     1316         288            297
//      file_edit         1296         277            298
//      file_read         1128         261            274
//      memory_write       991         211            221
//      file_write         970         213            226
//      memory_get         977         208            217
//      read_image         846         190            199
//      TOTAL                         3280           3452
//
//  `browser_use` is half the entire tool surface on its own — its description
//  is 2718 characters and it declares 23 parameters. On a frontier model with a
//  200K window that is free. On a 4B model with 32K it is 5% of the context
//  spent, in every single request, on a capability most turns never touch, and
//  it is 23 parameters of schema for a model that struggles to fill four
//  correctly.
//
//  So: the four core tools are permanent, and the specialists are disclosed
//  when something in the conversation indicates they are wanted. Measured
//  effect is a 68% reduction in permanent tool-schema tokens.
//
//  WHY DISCLOSURE IS STICKY
//
//  Adding a tool mid-conversation changes the rendered prompt prefix, which
//  invalidates the local model's KV cache and forces a full re-prefill of the
//  transcript (see LocalTranscriptDelta). So a capability, once disclosed,
//  stays disclosed for the rest of the session: at most one rebuild per
//  capability, rather than one per turn as triggers flicker on and off.
//
//  Remote models are unaffected. Their context is large, their prefix caching
//  is the server's problem, and changing their tool surface would be a
//  behaviour regression for no benefit.
//
//  Pure Foundation, unit-tested.
//

import Foundation

/// How much tool schema a model should carry permanently.
enum ToolSurfaceMode: String, Sendable, Equatable {
    /// Everything, every request. What Minis has always done, and what every
    /// remote provider keeps doing.
    case full
    /// Core tools permanently; specialists on demand. For local models, whose
    /// context is small and whose schema-following degrades with tool count.
    case lean
}

/// A specialist tool that isn't carried permanently in `lean` mode.
struct DeferredCapability: Sendable, Hashable {
    let toolName: String
    /// One short line for the "these exist" hint. Kept to a few words, because
    /// this is the part that IS permanent.
    let hint: String
    /// Lowercased substrings in the conversation that indicate this capability
    /// is wanted.
    let triggers: [String]
}

enum ToolSurfacePolicy {

    /// Tools every model always carries. These are the primitives everything
    /// else is built from, and the agent is useless without them.
    static let coreToolNames: Set<String> = [
        "shell_execute", "file_read", "file_write", "file_edit",
    ]

    /// Specialists, with what makes each one relevant.
    ///
    /// Triggers are deliberately broad — a false positive costs one extra tool
    /// schema for the rest of the session, while a false negative means the
    /// model cannot do something the user just asked for and has no way to
    /// discover that it could. Those are not symmetric.
    static let deferred: [DeferredCapability] = [
        DeferredCapability(
            toolName: "browser_use",
            hint: "web pages",
            triggers: [
                "http://", "https://", "www.", ".com", ".org", ".net", ".io",
                "browser", "browse", "website", "web page", "webpage", "web site",
                "screenshot", "screen shot", "click", "log in", "login", "sign in",
                "scrape", "download the page", "open the site", "url", "search the web",
            ]
        ),
        DeferredCapability(
            toolName: "read_image",
            hint: "view an image",
            triggers: [
                ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic",
                "image", "picture", "photo", "screenshot", "chart", "diagram",
                "look at", "what does it show", "see the",
            ]
        ),
        DeferredCapability(
            toolName: "memory_get",
            hint: "recall notes",
            triggers: [
                "remember", "recall", "memory", "you said", "last time",
                "previously", "we discussed", "my preference", "as usual",
            ]
        ),
        DeferredCapability(
            toolName: "memory_write",
            hint: "save a note",
            triggers: [
                "remember", "note that", "save this", "keep in mind",
                "for next time", "don't forget", "memorize", "memorise",
            ]
        ),
    ]

    /// Names of every tool that can be deferred.
    static var deferrableToolNames: Set<String> {
        Set(deferred.map(\.toolName))
    }

    /// The outcome of a selection.
    struct Selection: Sendable, Equatable {
        /// Tools to send with this request.
        let tools: [AgentToolDefinition]
        /// Capabilities withheld, for the prompt hint.
        let withheld: [DeferredCapability]
        /// Names disclosed so far in this session, to be carried into the next
        /// call so disclosure stays sticky.
        let disclosed: Set<String>

        static func == (lhs: Selection, rhs: Selection) -> Bool {
            lhs.tools.map(\.name) == rhs.tools.map(\.name)
                && lhs.withheld == rhs.withheld
                && lhs.disclosed == rhs.disclosed
        }
    }

    /// Choose the tool surface for one request.
    ///
    /// - Parameters:
    ///   - allTools: everything the app would normally send.
    ///   - mode: `.full` reproduces existing behaviour exactly.
    ///   - conversationText: recent conversation text to scan for triggers.
    ///     The caller decides how much history to include; the last couple of
    ///     turns is enough and keeps the scan cheap.
    ///   - alreadyDisclosed: names disclosed earlier in this session.
    static func select(
        allTools: [AgentToolDefinition],
        mode: ToolSurfaceMode,
        conversationText: String,
        alreadyDisclosed: Set<String>
    ) -> Selection {
        guard mode == .lean else {
            return Selection(tools: allTools, withheld: [],
                             disclosed: Set(allTools.map(\.name)))
        }

        let haystack = conversationText.lowercased()
        var disclosed = alreadyDisclosed
        for capability in deferred where !disclosed.contains(capability.toolName) {
            if capability.triggers.contains(where: haystack.contains) {
                disclosed.insert(capability.toolName)
            }
        }

        let deferrable = deferrableToolNames
        let selected = allTools.filter { tool in
            // Anything that isn't a known specialist is carried. That default
            // matters: a tool added upstream, or an MCP-provided one, must not
            // silently vanish because this table hasn't heard of it.
            !deferrable.contains(tool.name) || disclosed.contains(tool.name)
        }

        // Only advertise a capability the app actually has. When memory is
        // switched off its tools aren't in `allTools`, and hinting at them
        // would have the model promise something it can't do.
        let available = Set(allTools.map(\.name))
        let withheld = deferred.filter {
            available.contains($0.toolName) && !disclosed.contains($0.toolName)
        }

        return Selection(tools: selected, withheld: withheld, disclosed: disclosed)
    }

    /// The "these exist" hint for withheld capabilities.
    ///
    /// This is the part that IS permanent, so it is one line. Measured at 41
    /// Qwen 3.5 tokens for all four specialists — against the 2241 tokens their
    /// schemas would cost, a 54x return. Without it the model doesn't know the capability
    /// exists and will tell the user it cannot browse the web, which is worse
    /// than the tokens.
    static func withheldHint(_ withheld: [DeferredCapability]) -> String? {
        guard !withheld.isEmpty else { return nil }
        let list = withheld.map { "\($0.toolName) (\($0.hint))" }.joined(separator: ", ")
        return "Not loaded, available on request: \(list). Ask and it is enabled next turn."
    }

    /// Did the tool set change in a way that invalidates a local KV cache?
    ///
    /// Used to log and reason about the cost of a disclosure. The rebuild
    /// itself is handled by LocalTranscriptDelta via the tools hash; this is
    /// the human-readable side.
    static func disclosureChanged(from previous: Set<String>, to current: Set<String>) -> Bool {
        previous != current
    }
}
