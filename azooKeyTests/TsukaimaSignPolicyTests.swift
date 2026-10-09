import XCTest
@testable import azooKey

final class TsukaimaSignPolicyTests: XCTestCase {
    private func allows(main: Bool = true, scheme: String = "https", host: String = "api.yusukedoi.com", port: Int = 0,
                        method: String = "POST", path: String, body: Int = 10) -> Bool {
        TsukaimaSignPolicy.allows(isMainFrame: main, scheme: scheme, host: host, port: port, method: method, path: path, bodyBytes: body)
    }

    func testForgeRoutesAllowed() {
        XCTAssertTrue(allows(path: "/api/forge/sessions"))
        XCTAssertTrue(allows(path: "/api/forge/start"))
        XCTAssertTrue(allows(path: "/api/forge/sessions/ses_AbC123/prompt"))
        XCTAssertTrue(allows(path: "/api/forge/sessions/ses_AbC123/abort"))
        XCTAssertTrue(allows(port: 443, path: "/api/forge/start"))
        XCTAssertTrue(allows(path: "/api/voice-ab/vote"))
        XCTAssertTrue(allows(path: "/api/icons/pick"))
    }

    func testUntrustedOriginRejected() {
        XCTAssertFalse(allows(host: "evil.example", path: "/api/forge/start"))
        XCTAssertFalse(allows(host: "api.yusukedoi.com.evil.example", path: "/api/forge/start"))
        XCTAssertFalse(allows(host: "evil.api.yusukedoi.com", path: "/api/forge/start"))
        XCTAssertFalse(allows(scheme: "http", path: "/api/forge/start"))
        XCTAssertFalse(allows(scheme: "file", host: "", path: "/api/forge/start"))
        XCTAssertFalse(allows(port: 8443, path: "/api/forge/start"))
    }

    func testIframeRejected() {
        XCTAssertFalse(allows(main: false, path: "/api/forge/start"))
    }

    func testNonAllowlistedRejected() {
        XCTAssertFalse(allows(path: "/api/main/send"))
        XCTAssertFalse(allows(path: "/api/inbox"))
        XCTAssertFalse(allows(path: "/ws/blind"))
        XCTAssertFalse(allows(path: "/api/forge/start/"))
        XCTAssertFalse(allows(path: "/api/forge/sessions/ses_abc/prompt/x"))
        XCTAssertFalse(allows(path: "/api/forge/sessions/abc/prompt"))
        XCTAssertFalse(allows(path: "/api/forge/sessions/ses_/prompt"))
        XCTAssertFalse(allows(path: "/api/forge/sessions/ses_a%2Fb/prompt"))
        XCTAssertFalse(allows(path: "/api/forge/sessions/ses_abc/events"))
        XCTAssertFalse(allows(path: "/api/forge/start?x=1"))
        XCTAssertFalse(allows(method: "GET", path: "/api/forge/start"))
        XCTAssertFalse(allows(method: "DELETE", path: "/api/forge/sessions"))
    }

    func testOversizeBodyRejected() {
        XCTAssertFalse(allows(path: "/api/forge/sessions", body: TsukaimaSignPolicy.maxBodyBytes + 1))
        XCTAssertTrue(allows(path: "/api/forge/sessions", body: TsukaimaSignPolicy.maxBodyBytes))
    }
}
