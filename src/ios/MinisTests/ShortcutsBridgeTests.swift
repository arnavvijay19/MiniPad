import XCTest

/// Coverage for the Shortcuts bridge.
///
/// The theme running through these tests is that iOS gives third-party apps a
/// *run* interface and no *list* interface, and the agent has to be told the
/// truth about that or it will invent shortcut names and report success for
/// runs that never happened.
final class ShortcutsBridgeTests: XCTestCase {

    // MARK: - URL construction

    private func queryItems(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    func testRunURLUsesTheDocumentedXCallbackInterface() throws {
        let url = try ShortcutsBridge.runURL(
            name: "Log Weight", input: nil, token: "tok1", acceptsInput: false)
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "x-callback-url")
        XCTAssertEqual(url.path, "/run-shortcut")
        XCTAssertEqual(queryItems(url)["name"], "Log Weight")
    }

    func testAllThreeCallbacksAreRegistered() throws {
        // Without x-error and x-cancel, an abandoned run leaves the tool call
        // hanging until its timeout instead of reporting what happened.
        let items = queryItems(try ShortcutsBridge.runURL(
            name: "X", input: nil, token: "tok1", acceptsInput: false))
        XCTAssertNotNil(items["x-success"])
        XCTAssertNotNil(items["x-error"])
        XCTAssertNotNil(items["x-cancel"])
        XCTAssertTrue(items["x-success"]!.hasPrefix("minis://shortcut-callback"))
    }

    func testInputIsPassedAsTextNotAsAFileReference() throws {
        // `input=text` is what tells Shortcuts to treat the value as literal
        // text; without it a string that looks like a path is resolved as a
        // file and the shortcut receives something else entirely.
        let items = queryItems(try ShortcutsBridge.runURL(
            name: "Summarise", input: "hello world", token: "t", acceptsInput: true))
        XCTAssertEqual(items["input"], "text")
        XCTAssertEqual(items["text"], "hello world")
    }

    func testInputWithSpecialCharactersIsEncoded() throws {
        // Agent-generated input routinely contains ampersands and newlines; an
        // unencoded one truncates the URL and the shortcut silently receives a
        // fragment.
        let tricky = "a&b=c?d #e\nsecond line"
        let url = try ShortcutsBridge.runURL(
            name: "S", input: tricky, token: "t", acceptsInput: true)
        XCTAssertEqual(queryItems(url)["text"], tricky)
        XCTAssertFalse(url.absoluteString.contains("\n"))
    }

    func testShortcutNamesWithSpacesAndUnicodeSurvive() throws {
        let name = "Log Café ☕️ Entry"
        let url = try ShortcutsBridge.runURL(name: name, input: nil, token: "t", acceptsInput: false)
        XCTAssertEqual(queryItems(url)["name"], name)
    }

    func testEmptyNameIsRejected() {
        XCTAssertThrowsError(try ShortcutsBridge.runURL(
            name: "  ", input: nil, token: "t", acceptsInput: false))
    }

    func testInputToAShortcutThatTakesNoneIsRejectedWithAdvice() {
        // Passing input that will be ignored produces a shortcut that appears
        // to work and quietly does the wrong thing. Better to refuse and say
        // how to fix the registration.
        do {
            _ = try ShortcutsBridge.runURL(name: "NoInput", input: "x", token: "t", acceptsInput: false)
            XCTFail("expected a rejection")
        } catch let error as ShortcutsBridge.BuildError {
            XCTAssertEqual(error, .inputNotAccepted("NoInput"))
            XCTAssertTrue(error.localizedDescription.contains("accepting text"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testEmptyInputIsTreatedAsNoInput() throws {
        // A model that emits `"input": ""` for a no-input shortcut shouldn't
        // trip the rejection above.
        let items = queryItems(try ShortcutsBridge.runURL(
            name: "X", input: "", token: "t", acceptsInput: false))
        XCTAssertNil(items["text"])
    }

    // MARK: - Callback parsing

    func testSuccessCallbackWithResult() {
        let url = URL(string: "minis://shortcut-callback?token=tok1&outcome=success&result=42%20kg")!
        let callback = ShortcutsBridge.parseCallback(url)
        XCTAssertEqual(callback?.token, "tok1")
        XCTAssertEqual(callback?.outcome, .success(result: "42 kg"))
    }

    func testSuccessCallbackWithoutResultExplainsWhy() {
        // A shortcut with no "Stop and Output" returns nothing. Saying so stops
        // the model retrying the same call forever looking for output.
        let url = URL(string: "minis://shortcut-callback?token=t&outcome=success")!
        let outcome = ShortcutsBridge.parseCallback(url)?.outcome
        XCTAssertEqual(outcome, .success(result: nil))
        XCTAssertTrue(outcome!.modelFacingText.contains("Stop and Output"))
    }

    func testErrorCallbackCarriesTheMessage() {
        let url = URL(string: "minis://shortcut-callback?token=t&outcome=error&errorMessage=No%20such%20shortcut")!
        XCTAssertEqual(ShortcutsBridge.parseCallback(url)?.outcome,
                       .failure(message: "No such shortcut"))
    }

    func testCancelCallback() {
        let url = URL(string: "minis://shortcut-callback?token=t&outcome=cancel")!
        XCTAssertEqual(ShortcutsBridge.parseCallback(url)?.outcome, .cancelled)
    }

    func testUnrelatedMinisURLsAreNotClaimed() {
        // The app's existing deep-link router owns every other minis:// URL and
        // must keep handling them unchanged.
        for raw in ["minis://workspace/index.html", "minis://settings/skills",
                    "minis://open_terminal", "https://example.com/shortcut-callback"] {
            XCTAssertNil(ShortcutsBridge.parseCallback(URL(string: raw)!), raw)
        }
    }

    func testCallbackWithoutATokenIsRejected() {
        // A hand-triggered or malformed callback must not resolve someone's
        // pending run.
        XCTAssertNil(ShortcutsBridge.parseCallback(
            URL(string: "minis://shortcut-callback?outcome=success&result=x")!))
    }

    func testUnknownOutcomeIsRejected() {
        XCTAssertNil(ShortcutsBridge.parseCallback(
            URL(string: "minis://shortcut-callback?token=t&outcome=weird")!))
    }

    func testRoundTripThroughTheGeneratedCallbackURL() throws {
        // The URL we hand to Shortcuts must be one we can parse back.
        let token = ShortcutsBridge.makeToken()
        let url = ShortcutsBridge.callbackURL(token: token, outcome: "success")
        XCTAssertEqual(ShortcutsBridge.parseCallback(url)?.token, token)
    }

    func testTokensAreUnique() {
        let tokens = (0..<200).map { _ in ShortcutsBridge.makeToken() }
        XCTAssertEqual(Set(tokens).count, tokens.count)
    }

    // MARK: - Pending runs

    func testPendingRunIsClaimedExactlyOnce() {
        var pending = PendingShortcutRuns()
        pending.register(token: "a", shortcutName: "S")
        XCTAssertEqual(pending.claim(token: "a")?.shortcutName, "S")
        XCTAssertNil(pending.claim(token: "a"), "a claimed run must not resolve twice")
    }

    func testConcurrentRunsOfTheSameShortcutDoNotCrossResolve() {
        // The reason correlation is by token, not by name: two runs of the same
        // shortcut would otherwise deliver each other's results.
        var pending = PendingShortcutRuns()
        pending.register(token: "one", shortcutName: "Weather")
        pending.register(token: "two", shortcutName: "Weather")
        XCTAssertEqual(pending.count, 2)
        XCTAssertNotNil(pending.claim(token: "two"))
        XCTAssertTrue(pending.contains(token: "one"))
    }

    func testUnknownTokenIsIgnored() {
        // Stale callback from a previous launch, or one the user triggered by
        // hand.
        var pending = PendingShortcutRuns()
        XCTAssertNil(pending.claim(token: "ghost"))
    }

    func testStaleRunsExpire() {
        // Otherwise the table grows for the life of the process whenever a user
        // walks away from a Shortcuts permission prompt.
        var pending = PendingShortcutRuns()
        let old = Date().addingTimeInterval(-PendingShortcutRuns.timeout - 10)
        pending.register(token: "old", shortcutName: "S", now: old)
        pending.register(token: "new", shortcutName: "S")
        let expired = pending.expire()
        XCTAssertEqual(expired.map(\.token), ["old"])
        XCTAssertEqual(pending.count, 1)
    }

    func testTimeoutIsGenerousEnoughForAPermissionPrompt() {
        // A premature timeout reports failure for a shortcut that is about to
        // succeed, which is worse than waiting.
        XCTAssertGreaterThanOrEqual(PendingShortcutRuns.timeout, 120)
    }
}

// MARK: - Registry

final class ShortcutRegistryTests: XCTestCase {

    private let shortcuts = [
        ShortcutDescriptor(name: "Log Weight", summary: "Writes a weight to Health",
                           inputKind: .text, returnsOutput: false),
        ShortcutDescriptor(name: "Get Commute", summary: "Returns travel time home",
                           inputKind: .none, returnsOutput: true),
        ShortcutDescriptor(name: "Disabled One", summary: "x", enabled: false),
    ]

    func testFragmentListsOnlyEnabledShortcuts() {
        let fragment = ShortcutRegistry.promptFragment(shortcuts)!
        XCTAssertTrue(fragment.contains("Log Weight"))
        XCTAssertTrue(fragment.contains("Get Commute"))
        XCTAssertFalse(fragment.contains("Disabled One"))
    }

    func testFragmentStatesTheEnumerationLimit() {
        // Without this sentence the model invents an answer to "what shortcuts
        // do I have?" — the single most likely question about this feature.
        let fragment = ShortcutRegistry.promptFragment(shortcuts)!
        XCTAssertTrue(fragment.contains("no way to enumerate"))
    }

    func testFragmentWarnsAboutTheAppSwitch()  {
        // Running a shortcut foregrounds the Shortcuts app. A model that
        // doesn't know that will scatter shortcut calls through a long task.
        let fragment = ShortcutRegistry.promptFragment(shortcuts)!
        XCTAssertTrue(fragment.contains("switches to the Shortcuts app"))
    }

    func testFragmentDeclaresWhetherOutputComesBack() {
        let fragment = ShortcutRegistry.promptFragment(shortcuts)!
        XCTAssertTrue(fragment.contains("returns output"))
        XCTAssertTrue(fragment.contains("returns nothing"))
    }

    func testNoShortcutsMeansNoTokensSpent() {
        // A user who never touches this feature must pay nothing for it.
        XCTAssertNil(ShortcutRegistry.promptFragment([]))
        XCTAssertNil(ShortcutRegistry.promptFragment(
            [ShortcutDescriptor(name: "x", enabled: false)]))
    }

    func testLookupToleratesModelCasingAndSpacing() {
        // The model will not reproduce the user's capitalisation reliably.
        XCTAssertEqual(ShortcutRegistry.find("log weight", in: shortcuts)?.name, "Log Weight")
        XCTAssertEqual(ShortcutRegistry.find("  LOG WEIGHT ", in: shortcuts)?.name, "Log Weight")
        XCTAssertEqual(ShortcutRegistry.find("logweight", in: shortcuts)?.name, "Log Weight")
    }

    func testLookupDoesNotGuess() {
        // Fuzzy-matching an unregistered name would run the WRONG shortcut on
        // the user's device.
        XCTAssertNil(ShortcutRegistry.find("Log", in: shortcuts))
        XCTAssertNil(ShortcutRegistry.find("Weight Log", in: shortcuts))
    }

    func testFragmentIsCompactEnoughForASmallModel() {
        // This rides in every request once configured. Ten shortcuts must not
        // cost more than a few hundred tokens.
        let many = (0..<10).map {
            ShortcutDescriptor(name: "Shortcut \($0)", summary: "Does thing \($0)",
                               inputKind: .text, returnsOutput: true)
        }
        let fragment = ShortcutRegistry.promptFragment(many)!
        XCTAssertLessThan(fragment.count, 1200, "fragment is \(fragment.count) chars")
    }
}
