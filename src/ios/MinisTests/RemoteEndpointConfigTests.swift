import XCTest

/// Coverage for remote-endpoint configuration, with most of the weight on the
/// plaintext rule.
///
/// Everything this endpoint does is arbitrary code execution on the user's PC.
/// An unencrypted MCP endpoint reachable from the public internet is therefore
/// a remote shell for anyone on the path — so plain `http` is allowed to a
/// private LAN address (the actual deployment, where TLS would mean
/// self-signed-certificate management for no gain) and refused to anything
/// routable.
final class RemoteEndpointConfigTests: XCTestCase {

    private func config(_ url: String) -> RemoteEndpointConfig {
        RemoteEndpointConfig(displayName: "Desktop", urlString: url)
    }

    // MARK: Structural validation

    func testEmptyAndMalformedURLs() {
        XCTAssertEqual(config("").validate(), .emptyURL)
        XCTAssertEqual(config("   ").validate(), .emptyURL)
        XCTAssertEqual(config("ftp://host/x").validate(), .unsupportedScheme("ftp"))
        XCTAssertEqual(config("http://").validate(), .missingHost)
    }

    func testTypicalLANEndpointIsAccepted() {
        // The shape the user actually runs.
        XCTAssertNil(config("http://192.168.1.10:8766/mcp").validate())
    }

    func testHTTPSIsAlwaysAccepted() {
        XCTAssertNil(config("https://desk.example.com/mcp").validate())
    }

    // MARK: The plaintext rule

    func testPlainHTTPToAPublicHostIsRefused() {
        guard case .plaintextOverInternet = config("http://example.com/mcp").validate() else {
            return XCTFail("a routable plaintext endpoint must be refused")
        }
        guard case .plaintextOverInternet = config("http://8.8.8.8:8766/mcp").validate() else {
            return XCTFail("a public IP with plaintext must be refused")
        }
    }

    func testPrivateRangesAreRecognised() {
        for host in ["127.0.0.1", "localhost", "10.0.0.5", "172.16.0.1", "172.31.255.254",
                     "192.168.1.10", "169.254.1.1", "100.64.0.1", "desktop.local", "nuc"] {
            XCTAssertTrue(RemoteEndpointConfig.isPrivateOrLocal(host: host), "\(host) should be private")
        }
    }

    func testPublicRangesAreNotMistakenForPrivate() {
        // 172.15 and 172.32 sit just outside 172.16/12; 100.128 just outside
        // the CGNAT block. Off-by-one here would allow plaintext to the
        // internet, so the boundaries are pinned explicitly.
        for host in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "100.128.0.1",
                     "192.169.0.1", "example.com", "api.github.com"] {
            XCTAssertFalse(RemoteEndpointConfig.isPrivateOrLocal(host: host), "\(host) should be public")
        }
    }

    func testIPv6LoopbackAndUniqueLocal() {
        XCTAssertTrue(RemoteEndpointConfig.isPrivateOrLocal(host: "::1"))
        XCTAssertTrue(RemoteEndpointConfig.isPrivateOrLocal(host: "fd00::1"))
        XCTAssertTrue(RemoteEndpointConfig.isPrivateOrLocal(host: "fe80::1"))
    }

    func testTailscaleStyleCGNATAddressIsPrivate() {
        // 100.64/10 is what a Tailscale/Headscale tunnel hands out, and running
        // plain http over it is exactly as safe as a LAN.
        XCTAssertNil(config("http://100.101.102.103:8766/mcp").validate())
    }

    // MARK: Redaction

    func testRedactedURLDropsTheQueryString() {
        // Tunnel tokens ride in query strings; they must never reach a log.
        let c = RemoteEndpointConfig(displayName: "d", urlString: "https://host:9/mcp?token=SECRET")
        XCTAssertEqual(c.redactedURL, "https://host:9/mcp?<redacted>")
        XCTAssertFalse(c.redactedURL.contains("SECRET"))
    }

    func testRedactedURLKeepsEnoughToBeUseful() {
        let c = config("http://192.168.1.10:8766/mcp")
        XCTAssertEqual(c.redactedURL, "http://192.168.1.10:8766/mcp")
    }

    // MARK: Host label

    func testHostLabelPrefersTheUsersName() {
        XCTAssertEqual(config("http://192.168.1.10:8766/mcp").hostLabel, "Desktop")
        let unnamed = RemoteEndpointConfig(displayName: "", urlString: "http://192.168.1.10:8766/mcp")
        XCTAssertEqual(unnamed.hostLabel, "192.168.1.10")
    }

    // MARK: Header resolution

    private struct Secrets: RemoteEndpointSecretStore {
        var tokens: [String: String] = [:]
        var env: [String: String] = [:]
        func bearerToken(endpointId: String) -> String? { tokens[endpointId] }
        func environmentValue(_ name: String) -> String? { env[name] }
    }

    func testBearerTokenComesFromTheSecretStoreNotTheConfig() {
        // The config is synced and written to disk; the token is not in it.
        var c = config("http://192.168.1.10:8766/mcp")
        c.usesBearerToken = true
        var secrets = Secrets()
        secrets.tokens[c.id] = "abc"
        let (headers, unresolved) = c.resolvedHeaders(secrets: secrets)
        XCTAssertEqual(headers["Authorization"], "Bearer abc")
        XCTAssertTrue(unresolved.isEmpty)

        // And the config itself never carries it, even after encoding.
        let encoded = String(data: try! JSONEncoder().encode(c), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("abc"))
    }

    func testEnvironmentPlaceholdersResolve() {
        var c = config("http://192.168.1.10:8766/mcp")
        c.headers = ["X-Token": "$$MY_TOKEN", "X-Plain": "literal"]
        var secrets = Secrets()
        secrets.env["MY_TOKEN"] = "resolved"
        let (headers, unresolved) = c.resolvedHeaders(secrets: secrets)
        XCTAssertEqual(headers["X-Token"], "resolved")
        XCTAssertEqual(headers["X-Plain"], "literal")
        XCTAssertTrue(unresolved.isEmpty)
    }

    func testUnresolvedPlaceholdersAreReportedNotSentLiterally() {
        // Sending "$$MY_TOKEN" as a credential yields a confusing 401 instead
        // of the actionable "that variable isn't set".
        var c = config("http://192.168.1.10:8766/mcp")
        c.headers = ["X-Token": "$$MISSING"]
        let (headers, unresolved) = c.resolvedHeaders(secrets: Secrets())
        XCTAssertNil(headers["X-Token"])
        XCTAssertEqual(unresolved, ["MISSING"])
    }

    func testNoBearerHeaderWhenTheEndpointDoesNotUseOne() {
        let c = config("http://192.168.1.10:8766/mcp")
        var secrets = Secrets()
        secrets.tokens[c.id] = "stale"
        let (headers, _) = c.resolvedHeaders(secrets: secrets)
        XCTAssertNil(headers["Authorization"])
    }
}
