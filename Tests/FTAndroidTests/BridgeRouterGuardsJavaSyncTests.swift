// Android ブリッジ(AndroidRunner/)の3つの門をソース走査で固定する。
// ①handleLaunch の前面掃除は SYSTEM_DIALOG_PACKAGES(権限ダイアログ・systemui 等)を force-stop しない
//   —— 殺すとアプリの権限フローが壊れ「前面に来ない」を自分で作る。集合はホスト
//   (Sources/fleetest-mcp/MCPServer+Driver.swift の systemDialogPackages)と同期する
// ②既定スワイプ・ピンチの基準矩形に 1080x2400 の固定値を置かない(snapshot 前の swipe が
//   別解像度で画面外を払っていた)
// ③QuietWaiter は既定 IME(Settings.Secure.DEFAULT_INPUT_METHOD)へ静穏対象を追従させない
//   (キーボード出現後のアプリ側の再レイアウトを待たずに /tap が返っていた)

import XCTest

final class BridgeRouterGuardsJavaSyncTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var routerSource: String {
        get throws { try source("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java") }
    }

    private var quietWaiterSource: String {
        get throws { try source("AndroidRunner/src/com/example/ftbridge/QuietWaiter.java") }
    }

    /// コメントを除いたコード(Javadoc の `*` 行と `//` 以降を落とす)
    private func code(_ source: String) -> String {
        source.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return nil }
            return line.components(separatedBy: "//")[0]
        }.joined(separator: "\n")
    }

    /// 走査の前提(シグネチャ・閉じ括弧)が崩れたら**落とす**(skip にすると改名で門が黙って消える)
    private struct SourceShapeBroken: Error, CustomStringConvertible {
        let description: String
    }

    /// メソッド本体(シグネチャの出現位置から 4 スペース字下げの閉じ括弧まで。宣言なら terminator を指定)
    private func body(of signature: String, in source: String, terminator: String = "\n    }\n") throws -> String {
        guard let start = source.range(of: signature) else {
            throw SourceShapeBroken(description: "\(signature) が見つからない(改名したら走査も直す)")
        }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: terminator) else {
            throw SourceShapeBroken(description: "\(signature) の閉じ括弧が見つからない")
        }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - ①システムのダイアログは force-stop しない

    /// ホストの systemDialogPackages の全エントリが Java 側の集合に居る(片方だけ変えない)
    func testSystemDialogPackagesMatchTheHostList() throws {
        let host = try source("Sources/fleetest-mcp/MCPServer+Driver.swift")
        let hostDecl = try body(of: "static let systemDialogPackages: Set<String> = [", in: host,
                                terminator: "\n    ]")
        let hostEntries = hostDecl.components(separatedBy: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertGreaterThanOrEqual(hostEntries.count, 5, "ホストの一覧が読めていない")

        let javaDecl = try body(of: "static final Set<String> SYSTEM_DIALOG_PACKAGES = new HashSet<>(Arrays.asList(",
                                in: code(try routerSource), terminator: "\n    ));")
        for entry in hostEntries {
            XCTAssertTrue(javaDecl.contains("\"\(entry)\""), "\(entry) が BridgeRouter.SYSTEM_DIALOG_PACKAGES に無い")
        }
        XCTAssertTrue(javaDecl.contains("\"com.android.chrome\""), "Custom Tab(chrome)はこちらだけの追加")
    }

    /// handleLaunch は stuck を force-stop する前に SYSTEM_DIALOG_PACKAGES で門を掛け、該当なら成功を返す
    func testForceStopIsGuardedBySystemDialogList() throws {
        let launch = try body(of: "private BridgeHttpServer.Response handleLaunch(JSONObject body)",
                              in: code(try routerSource))
        guard let guardRange = launch.range(of: "SYSTEM_DIALOG_PACKAGES.contains(stuck)"),
              let stopRange = launch.range(of: "\"am force-stop \" + stuck") else {
            return XCTFail("門(SYSTEM_DIALOG_PACKAGES.contains(stuck))か force-stop が handleLaunch に無い")
        }
        XCTAssertLessThan(guardRange.lowerBound, stopRange.lowerBound, "門は force-stop より前に置く")
        let afterGuard = launch[guardRange.upperBound..<stopRange.lowerBound]
        XCTAssertTrue(afterGuard.contains("return ok();"), "該当時は成功を返す(再試行の force-stop でアプリごと畳まない)")
    }

    /// 前面判定のポーリングは「ダイアログの下にアプリのウィンドウが見えている」で早期に抜ける
    func testLaunchPollAcceptsAppUnderSystemDialog() throws {
        let attempt = try body(of: "private boolean attemptLaunch(String bundleID)", in: code(try routerSource))
        XCTAssertTrue(attempt.contains("SYSTEM_DIALOG_PACKAGES.contains(pkg) && hasWindowOf(bundleID)"))
    }

    // MARK: - ②既定の画面サイズを仮定しない

    func testSwipeAndPinchDoNotAssumeADisplaySize() throws {
        let router = code(try routerSource)
        for signature in ["private BridgeHttpServer.Response handleSwipe(JSONObject body)",
                          "private BridgeHttpServer.Response handlePinch(JSONObject body)"] {
            let method = try body(of: signature, in: router)
            XCTAssertFalse(method.contains("1080"), "\(signature) に固定の幅が残っている")
            XCTAssertFalse(method.contains("2400"), "\(signature) に固定の高さが残っている")
            XCTAssertTrue(method.contains("screenRect()"), "\(signature) は screenRect() を基準にする")
        }
        let screenRect = try body(of: "private Rect screenRect()", in: router)
        XCTAssertTrue(screenRect.contains("lastScreen"), "直近の snapshot があればそれを使う")
        XCTAssertTrue(screenRect.contains("getMaximumWindowMetrics()") && screenRect.contains("getRealMetrics("),
                      "API 30+ / 未満の両方でディスプレイの実寸を引く(minSdk 26)")
        XCTAssertFalse(screenRect.contains("1080") || screenRect.contains("2400"))
    }

    // MARK: - ③IME へ静穏対象を追従させない

    func testQuietWaiterExcludesTheDefaultIME() throws {
        let waiter = code(try quietWaiterSource)
        XCTAssertTrue(waiter.contains("Settings.Secure.DEFAULT_INPUT_METHOD"), "既定 IME を Settings.Secure から読む")
        XCTAssertEqual(waiter.components(separatedBy: "Settings.Secure.getString(").count - 1, 1,
                       "読むのは構築時の1回だけ")
        XCTAssertTrue(waiter.contains(".contains(\".inputmethod\")"), "読めないときの名前による退避")
        let onEvent = try body(of: "private void onEvent(AccessibilityEvent event)", in: waiter)
        XCTAssertTrue(onEvent.contains("!isRetargetExcluded(pkg)"), "追従の門は isRetargetExcluded の1箇所")
        XCTAssertFalse(onEvent.contains("RETARGET_EXCLUDED_PACKAGES.contains(pkg)"),
                       "静的集合だけで判定する旧形が残っている")
        XCTAssertTrue(code(try routerSource).contains("new QuietWaiter(instrumentation.getContext())"),
                      "BridgeRouter は context 付きで構築する(フィールド初期化子では instrumentation が null)")
    }
}
