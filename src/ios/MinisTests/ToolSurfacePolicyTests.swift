import XCTest

/// Coverage for lazy tool disclosure.
///
/// The measurement that motivates this (scripts/measure_tool_context.py, real
/// Qwen 3.5 and Gemma 4 tokenizers) is that `browser_use` costs 1632 tokens —
/// half the whole tool surface — and most turns never touch it. These tests pin
/// both halves of the bargain: the saving is real, and nothing the agent needs
/// silently disappears.
final class ToolSurfacePolicyTests: XCTestCase {

    private func tool(_ name: String, params: Int = 2) -> AgentToolDefinition {
        var parameters: [String: AgentToolParam] = [:]
        for i in 0..<params {
            parameters["p\(i)"] = AgentToolParam(type: .string, description: "param \(i)")
        }
        return AgentToolDefinition(name: name, description: "desc for \(name)",
                                   parameters: parameters, required: [])
    }

    private var allTools: [AgentToolDefinition] {
        ["shell_execute", "file_read", "file_write", "file_edit",
         "browser_use", "read_image", "memory_get", "memory_write", "windows_control"].map { tool($0) }
    }

    private func names(_ selection: ToolSurfacePolicy.Selection) -> Set<String> {
        Set(selection.tools.map(\.name))
    }

    // MARK: Full mode

    func testFullModeIsUnchangedBehaviour() {
        // Remote providers must see exactly what they saw before. A regression
        // here is a behaviour change for every existing user.
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .full, conversationText: "", alreadyDisclosed: [])
        XCTAssertEqual(selection.tools.count, allTools.count)
        XCTAssertTrue(selection.withheld.isEmpty)
        XCTAssertNil(ToolSurfacePolicy.withheldHint(selection.withheld))
    }

    // MARK: Lean mode

    func testLeanModeKeepsTheCoreAndDefersTheRest() {
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "write a python script",
            alreadyDisclosed: [])
        XCTAssertEqual(names(selection), ToolSurfacePolicy.coreToolNames)
        XCTAssertEqual(Set(selection.withheld.map(\.toolName)),
                       ToolSurfacePolicy.deferrableToolNames)
    }

    func testCoreToolsAreNeverDeferred() {
        // The agent is useless without these; no trigger logic may withhold one.
        for text in ["", "browse the web", "remember this", "look at the image"] {
            let selection = ToolSurfacePolicy.select(
                allTools: allTools, mode: .lean, conversationText: text, alreadyDisclosed: [])
            XCTAssertTrue(ToolSurfacePolicy.coreToolNames.isSubset(of: names(selection)),
                          "core missing for text: '\(text)'")
        }
    }

    // MARK: Triggers

    func testURLDisclosesTheBrowser() {
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean,
            conversationText: "summarise https://example.com/article", alreadyDisclosed: [])
        XCTAssertTrue(names(selection).contains("browser_use"))
    }

    func testBrowserVocabularyDisclosesTheBrowser() {
        for text in ["open the website", "take a screenshot of the page",
                     "log in to my account", "scrape that table", "check the web page"] {
            let selection = ToolSurfacePolicy.select(
                allTools: allTools, mode: .lean, conversationText: text, alreadyDisclosed: [])
            XCTAssertTrue(names(selection).contains("browser_use"), "missed: '\(text)'")
        }
    }

    func testImageVocabularyDisclosesReadImage() {
        for text in ["look at chart.png", "what does the diagram show",
                     "inspect the screenshot"] {
            let selection = ToolSurfacePolicy.select(
                allTools: allTools, mode: .lean, conversationText: text, alreadyDisclosed: [])
            XCTAssertTrue(names(selection).contains("read_image"), "missed: '\(text)'")
        }
    }

    func testMemoryVocabularyDisclosesMemoryTools() {
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean,
            conversationText: "remember that I prefer tabs", alreadyDisclosed: [])
        XCTAssertTrue(names(selection).contains("memory_get"))
        XCTAssertTrue(names(selection).contains("memory_write"))
    }

    func testTriggersAreCaseInsensitive() {
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean,
            conversationText: "Open HTTPS://EXAMPLE.COM Please", alreadyDisclosed: [])
        XCTAssertTrue(names(selection).contains("browser_use"))
    }

    func testOrdinaryShellWorkDisclosesNothingExtra() {
        // The case that pays for the whole mechanism.
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean,
            conversationText: "run the tests in /var/minis/workspace and fix the failure",
            alreadyDisclosed: [])
        XCTAssertEqual(names(selection), ToolSurfacePolicy.coreToolNames)
    }

    // MARK: Stickiness

    func testDisclosureIsSticky() {
        // Adding a tool changes the prompt prefix and forces a local KV-cache
        // rebuild. Sticky disclosure means at most one rebuild per capability
        // instead of one per turn as triggers flicker.
        let first = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "open https://example.com",
            alreadyDisclosed: [])
        XCTAssertTrue(first.disclosed.contains("browser_use"))

        let second = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "now write a file",
            alreadyDisclosed: first.disclosed)
        XCTAssertTrue(names(second).contains("browser_use"),
                      "a disclosed capability must not be withdrawn")
    }

    func testStickyDisclosureStopsChangingTheToolSet() {
        var disclosed: Set<String> = []
        let texts = ["open https://a.com", "click the button", "now read /tmp/x", "and again"]
        var previous: Set<String> = []
        var changes = 0
        for text in texts {
            let selection = ToolSurfacePolicy.select(
                allTools: allTools, mode: .lean, conversationText: text,
                alreadyDisclosed: disclosed)
            disclosed = selection.disclosed
            if ToolSurfacePolicy.disclosureChanged(from: previous, to: disclosed) { changes += 1 }
            previous = disclosed
        }
        XCTAssertLessThanOrEqual(changes, 2, "tool set churned \(changes) times")
    }

    // MARK: Unknown tools

    func testUnknownToolsAreAlwaysCarried() {
        // A tool added upstream, or provided by an MCP server, must not vanish
        // because this policy's table hasn't heard of it.
        let withExtra = allTools + [tool("some_new_upstream_tool")]
        let selection = ToolSurfacePolicy.select(
            allTools: withExtra, mode: .lean, conversationText: "hello", alreadyDisclosed: [])
        XCTAssertTrue(names(selection).contains("some_new_upstream_tool"))
    }

    // MARK: Hint

    func testHintNamesWithheldCapabilities() {
        // Without it the model tells the user it cannot browse the web, which
        // is worse than the tokens the hint costs.
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "hello", alreadyDisclosed: [])
        let hint = ToolSurfacePolicy.withheldHint(selection.withheld)!
        XCTAssertTrue(hint.contains("browser_use"))
        XCTAssertTrue(hint.contains("read_image"))
    }

    func testHintIsSmallEnoughToBeWorthIt() {
        // ~35 tokens against the 2241 the withheld schemas would cost.
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "hello", alreadyDisclosed: [])
        let hint = ToolSurfacePolicy.withheldHint(selection.withheld)!
        XCTAssertLessThan(hint.count, 260, "hint is \(hint.count) chars")
    }

    func testHintDisappearsWhenEverythingIsDisclosed() {
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "hello",
            alreadyDisclosed: ToolSurfacePolicy.deferrableToolNames)
        XCTAssertNil(ToolSurfacePolicy.withheldHint(selection.withheld))
    }

    func testHintNeverAdvertisesAToolTheAppDoesNotHave() {
        // With memory switched off its tools aren't in the list at all; hinting
        // at them would have the model promise something it can't do.
        let withoutMemory = allTools.filter { !$0.name.hasPrefix("memory_") }
        let selection = ToolSurfacePolicy.select(
            allTools: withoutMemory, mode: .lean, conversationText: "remember this",
            alreadyDisclosed: [])
        let hint = ToolSurfacePolicy.withheldHint(selection.withheld) ?? ""
        XCTAssertFalse(hint.contains("memory_"))
    }

    // MARK: The saving

    func testLeanModeRemovesTheExpensiveTools() {
        // The measured saving is 68% of tool-schema tokens, and it comes almost
        // entirely from browser_use.
        let selection = ToolSurfacePolicy.select(
            allTools: allTools, mode: .lean, conversationText: "write some code",
            alreadyDisclosed: [])
        XCTAssertFalse(names(selection).contains("browser_use"))
        XCTAssertEqual(selection.tools.count, 4)
        XCTAssertEqual(allTools.count, 9)
    }
}
