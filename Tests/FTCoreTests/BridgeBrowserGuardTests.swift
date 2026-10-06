// ブリッジはブラウザが送った要求を断る(BridgeAPI.browserRequestRefusal)。ループバックの待受には
// 認証が無いので、閲覧中のページからの POST(応答を読まなくても操作は届く)と DNS リバインディングで
// 端末を操作・観測できていた。3つのサーバ(XCUITest ランナー・in-app・Android)の配線と Java の写しも縛る。

import XCTest
@testable import FTCore

final class BridgeBrowserGuardTests: XCTestCase {

    private func refusal(origin: String? = nil, site: String? = nil, host: String? = "127.0.0.1:8123",
                         loopback: Bool = true) -> String? {
        BridgeAPI.browserRequestRefusal(origin: origin, secFetchSite: site, host: host, requireLoopbackHost: loopback)
    }

    /// 正規の呼び手(URLSession・Java・curl)が付けるヘッダの形はすべて通す
    func testLegitimateClientsPass() {
        for host in ["127.0.0.1:8123", "127.0.0.1", "localhost:8123", "LOCALHOST", "[::1]:8123", "::1", nil] {
            XCTAssertNil(refusal(host: host), host ?? "nil")
        }
        XCTAssertNil(refusal(site: "none"), "人がアドレス欄に打った要求")
        XCTAssertNil(refusal(host: "192.168.20.50:8123", loopback: false), "トークンで守る LAN の実機")
    }

    func testBrowserRequestsAreRefused() {
        XCTAssertEqual(refusal(origin: "https://evil.example"),
                       "requests from a web page are not accepted (Origin header)")
        XCTAssertNotNil(refusal(origin: "null"))
        XCTAssertEqual(refusal(site: "cross-site"),
                       "requests from a web page are not accepted (Sec-Fetch-Site: cross-site)")
        XCTAssertNotNil(refusal(site: "same-site"))
        XCTAssertNotNil(refusal(origin: "https://evil.example", loopback: false), "LAN の待受でもブラウザは断る")
    }

    /// DNS リバインディング: ホスト名を 127.0.0.1 へ向け直しても Host は攻撃者の名前のまま
    func testNonLoopbackHostIsRefusedOnlyWithoutAToken() {
        XCTAssertEqual(refusal(host: "evil.example:8123"),
                       "requests must address the loopback interface (Host: evil.example:8123)")
        XCTAssertNotNil(refusal(host: "127.0.0.1.evil.example"))
        XCTAssertNotNil(refusal(host: "[::2]:8123"))
        XCTAssertNil(refusal(host: "evil.example:8123", loopback: false))
    }

    // MARK: - 3つのサーバの配線(どれも swift test ではコンパイルされないのでソースで見る)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func code(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("*") }
            .map { $0.components(separatedBy: "//")[0] }
            .joined(separator: "\n")
    }

    func testEveryBridgeServerConsultsTheGuardBeforeDispatching() throws {
        let runner = try code("Runner/FleetestRunnerUITests/BridgeHTTPServer.swift")
        let inApp = try code("InAppBridge/Sources/InAppHTTPServer.swift")
        let android = try code("AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java")
        for (name, source, call, dispatch) in [
            ("runner", runner, "BridgeAPI.browserRequestRefusal(", "dispatchToMain(request)"),
            ("in-app", inApp, "BridgeAPI.browserRequestRefusal(", "handler(request)"),
            ("android", android, "browserRequestRefusal(request.origin", "handler.handle(request)"),
        ] {
            let guardAt = try XCTUnwrap(source.range(of: call), "\(name): 門が配線されていない")
            let dispatchAt = try XCTUnwrap(source.range(of: dispatch), "\(name): 走査の前提が崩れた")
            XCTAssertLessThan(guardAt.lowerBound, dispatchAt.lowerBound, "\(name): 門がハンドラの後にある")
            for header in ["\"origin\"", "\"sec-fetch-site\"", "\"host\""] where name != "android" {
                XCTAssertTrue(source.contains("case \(header):"), "\(name): \(header) を読んでいない")
            }
        }
        // ランナーだけは LAN の待受(トークンで守る)で Host を見ない
        XCTAssertTrue(runner.contains("requireLoopbackHost: listensOnLoopbackOnly"))
        XCTAssertTrue(inApp.contains("requireLoopbackHost: true"))
    }
}

/// Android の写しが Swift の判定と同じ文言・同じホスト名を持つこと
final class BridgeBrowserGuardJavaSyncTests: XCTestCase {

    func testJavaCopyMatchesTheSwiftGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let java = try String(contentsOf: root.appendingPathComponent(
            "AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java"), encoding: .utf8)
        for literal in ["\"requests from a web page are not accepted (Origin header)\"",
                        "\"requests from a web page are not accepted (Sec-Fetch-Site: \"",
                        "\"requests must address the loopback interface (Host: \"",
                        "equalsIgnoreCase(\"none\")",
                        "equalsIgnoreCase(\"Origin\")", "equalsIgnoreCase(\"Sec-Fetch-Site\")",
                        "equalsIgnoreCase(\"Host\")"] {
            XCTAssertTrue(java.contains(literal), literal)
        }
        for host in BridgeAPI.browserGuardLoopbackHosts {
            XCTAssertTrue(java.contains("name.equals(\"\(host)\")"), "Java が \(host) を許していない")
        }
        XCTAssertEqual(java.components(separatedBy: "name.equals(\"").count - 1,
                       BridgeAPI.browserGuardLoopbackHosts.count, "Java だけが許すホスト名がある")
        XCTAssertTrue(java.contains("Response.error(403, refusal)"))
    }
}
