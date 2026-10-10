// Android ブリッジ(AndroidRunner/.../BridgeRouter.java)の POST /waitForSettle のソース走査。
//
// Java は Swift のテストから呼べない(UiAutomation・Bitmap が要る)ので、契約の要所と撮影の計画をソースで固定する。
// 走査はコメントを落としてから行う(定数名・判定の名前は doc コメントにも出るので、素のまま検索すると
// 配線を消してもコメントだけで通る)。契約は Sources/FTCore/BridgeDTO.swift の WaitForSettleRequest。
// 定数の値を production の BridgeAPI と突き合わせる同期テストは、production の定数を期待値に使ってよい例外
// (GestureLimitsSyncTests と同じ。リテラルの固定と同期は別のテストで両方掛ける)。

import XCTest
import FTCore

final class AndroidWaitForSettleScanTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// コメント行(`//`・`/*`・`*` で始まる行)と行末の ` //` 以降を落とした BridgeRouter.java。
    /// 行単位で落とす: 文字列の中の `/*` を block コメントの始まりと取り違えて本物のコードを飲まないため
    private func routerSource() throws -> String {
        let url = repoRoot.appendingPathComponent("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { return nil }
            guard let range = line.range(of: " //") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }

    /// `<signature>` の後ろの最初の `{` から対応する `}` まで。見つからなければ失敗(走査が空振りしない確認を兼ねる)
    private func body(after signature: String, in source: String) -> String {
        guard let start = source.range(of: signature) else {
            XCTFail("BridgeRouter.java に \(signature) が見つかりません")
            return ""
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else {
            XCTFail("\(signature) の本体が見つかりません")
            return ""
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        XCTFail("\(signature) の本体が閉じていません")
        return ""
    }

    private func handler(_ source: String) -> String {
        normalized(body(after: "BridgeHttpServer.Response handleWaitForSettle(", in: source))
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// `static final <型> <name> = <値>;` の `<値>`(数字の `_` は除く)。無ければ nil
    private func javaConstant(_ name: String, in source: String) -> Double? {
        let pattern = "\(name)\\s*=\\s*([0-9._]+)\\s*;"
        guard let range = source.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = source[range]
        guard let eq = matched.firstIndex(of: "="), let semi = matched.firstIndex(of: ";") else { return nil }
        let literal = matched[matched.index(after: eq)..<semi]
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        return Double(literal)
    }

    private func assertConstant(_ name: String, equals expected: Double, in source: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let value = javaConstant(name, in: source) else {
            return XCTFail("BridgeRouter.java に \(name) が見つかりません", file: file, line: line)
        }
        XCTAssertEqual(value, expected, "\(name) の値が設計(計測)と違います", file: file, line: line)
    }

    // MARK: - ルート

    /// ルートが消える/ハンドラ名が変わると、ブリッジは 404 を返してホストの waitForSettle が全部落ちる
    func testRouteIsRegistered() throws {
        let source = normalized(try routerSource())
        XCTAssertNotNil(
            source.range(of: #"case "POST /waitForSettle": return handleWaitForSettle\(body\(request\)\);"#,
                         options: .regularExpression),
            "POST /waitForSettle のルートが handle の switch にありません")
    }

    // MARK: - 定数

    /// 撮影間隔の3つの定数は計測で決めた値(エミュレータの撮影はホストの CPU を使う)。動かすなら計測してから
    func testScheduleConstantsKeepTheirMeasuredValues() throws {
        let source = try routerSource()
        assertConstant("WAIT_FOR_SETTLE_FIRST_GAP_MS", equals: 50, in: source)
        assertConstant("WAIT_FOR_SETTLE_MAX_INTERVAL_MS", equals: 100, in: source)
        assertConstant("WAIT_FOR_SETTLE_REGION_INSET", equals: 0.1, in: source)
    }

    /// 削る割合はホスト(iOS ランナーと共有する FTCore)と同じ値。片方だけ変えると 2 OS で比べる範囲が食い違う
    func testRegionInsetMatchesTheHostConstant() throws {
        let source = try routerSource()
        guard let value = javaConstant("WAIT_FOR_SETTLE_REGION_INSET", in: source) else {
            return XCTFail("BridgeRouter.java に WAIT_FOR_SETTLE_REGION_INSET が見つかりません")
        }
        XCTAssertEqual(value, BridgeAPI.waitForSettleRegionInsetRatio,
                       "WAIT_FOR_SETTLE_REGION_INSET と BridgeAPI.waitForSettleRegionInsetRatio は同時に変えること")
    }

    /// 受け付け範囲の数字(窓 100〜5000・上限 0〜60000)。Java は BridgeAPI の写しを持つので、リテラルと同期の両方で固定する
    func testRangeConstantsKeepTheirValuesAndMatchTheHost() throws {
        let source = try routerSource()
        assertConstant("WAIT_FOR_SETTLE_QUIET_MIN_MS", equals: 100, in: source)
        assertConstant("WAIT_FOR_SETTLE_QUIET_MAX_MS", equals: 5000, in: source)
        assertConstant("WAIT_FOR_SETTLE_TIMEOUT_MIN_MS", equals: 0, in: source)
        assertConstant("WAIT_FOR_SETTLE_TIMEOUT_MAX_MS", equals: 60000, in: source)
        XCTAssertEqual(BridgeAPI.waitForSettleQuietRangeMs, 100...5000,
                       "Java の写し(WAIT_FOR_SETTLE_QUIET_*)と BridgeAPI.waitForSettleQuietRangeMs は同時に変えること")
        XCTAssertEqual(BridgeAPI.waitForSettleTimeoutRangeMs, 0...60000,
                       "Java の写し(WAIT_FOR_SETTLE_TIMEOUT_*)と BridgeAPI.waitForSettleTimeoutRangeMs は同時に変えること")
    }

    /// 窓と上限は両方とも範囲で丸める(ホストの門を通らない経路の最後の砦)。入れ替え・丸め忘れ・片側だけの丸めが落ちる
    func testHandlerClampsQuietAndTimeout() throws {
        let h = handler(try routerSource())
        XCTAssertNotNil(
            h.range(of: #"Math\.max\(WAIT_FOR_SETTLE_QUIET_MIN_MS, Math\.min\(body\.optLong\("quietMs"\), WAIT_FOR_SETTLE_QUIET_MAX_MS\)\)"#,
                    options: .regularExpression),
            "quietMs を QUIET_MIN/MAX で丸めていません")
        XCTAssertNotNil(
            h.range(of: #"Math\.max\(WAIT_FOR_SETTLE_TIMEOUT_MIN_MS, Math\.min\(body\.optLong\("timeoutMs"\), WAIT_FOR_SETTLE_TIMEOUT_MAX_MS\)\)"#,
                    options: .regularExpression),
            "timeoutMs を TIMEOUT_MIN/MAX で丸めていません")
    }

    // MARK: - 比べる範囲

    /// 縁を削る(スクロールバー・インジケータのフェードは止まった後も変わる)。幅と高さの両方に掛け、ハンドラがそれを通す
    func testInsetIsAppliedToBothAxesAndUsedByTheHandler() throws {
        let source = try routerSource()
        let bounds = normalized(body(after: "static int[] waitForSettleCompareBounds(", in: source))
        XCTAssertTrue(bounds.contains("w * WAIT_FOR_SETTLE_REGION_INSET"), "幅に削る割合を掛けていません")
        XCTAssertTrue(bounds.contains("h * WAIT_FOR_SETTLE_REGION_INSET"), "高さに削る割合を掛けていません")
        XCTAssertTrue(bounds.contains("w - 2 * dx") && bounds.contains("h - 2 * dy"),
                      "削った分を両側から引いていません(100×200 → 80×160)")
        XCTAssertTrue(handler(source).contains("waitForSettleCompareBounds(region, full.getWidth(), full.getHeight())"),
                      "撮った画像を削った範囲で切り出していません")
    }

    // MARK: - 撮影の計画

    /// 実機は連続・エミュレータは間引く(計測で決めた設計)。エミュレータの判定は ranchu / goldfish / sdk_ の3つ
    func testScheduleHasPhysicalAndEmulatorBranches() throws {
        let source = try routerSource()
        let next = normalized(body(after: "static long nextCaptureAt(", in: source))
        XCTAssertTrue(next.contains("if (!emulator) return lastAt;"), "実機が連続撮影(待たない)になっていません")
        XCTAssertTrue(next.contains("if (frames == 1) return firstAt + WAIT_FOR_SETTLE_FIRST_GAP_MS;"),
                      "エミュレータの 2 枚目が 1 枚目の FIRST_GAP 後になっていません")
        XCTAssertTrue(
            next.contains("changeStreak <= 1 ? WAIT_FOR_SETTLE_FIRST_GAP_MS : WAIT_FOR_SETTLE_MAX_INTERVAL_MS"),
            "変化が続く間の間隔が 50 → 100 になっていません")
        XCTAssertTrue(next.contains("lastChangeAt + quietMs / 2"), "一致した後の窓の中間の撮影がありません")
        XCTAssertTrue(next.contains("Math.max(lastAt, lastChangeAt + quietMs)"), "窓の満了時刻ちょうどの撮影がありません")

        let normalizedSource = normalized(source)
        for marker in [#""ranchu".equals(Build.HARDWARE)"#, #""goldfish".equals(Build.HARDWARE)"#,
                       #"Build.PRODUCT.startsWith("sdk_")"#] {
            XCTAssertTrue(normalizedSource.contains(marker), "IS_EMULATOR の判定に \(marker) がありません")
        }
        XCTAssertTrue(handler(source).contains("nextCaptureAt(IS_EMULATOR, frames, firstAt, lastAt, lastChangeAt,"),
                      "ハンドラが IS_EMULATOR で撮影の計画を引いていません")
    }

    // MARK: - 撮影と比較

    /// PNG エンコードを挟まず Bitmap 同士で比べる・必ず recycle する・撮れないときは整定したことにしない
    func testCompareAndFailureShape() throws {
        let h = handler(try routerSource())
        XCTAssertTrue(h.contains("ua().takeScreenshot()"), "UiAutomation のスクリーンショットで撮っていません")
        XCTAssertTrue(h.contains("sameAs("), "Bitmap.sameAs で比べていません")
        XCTAssertFalse(h.contains("compress("), "比較に PNG エンコードを挟んでいます")
        XCTAssertTrue(h.contains("recycle()"), "Bitmap を recycle していません")
        guard let range = h.range(of: #"if \(full == null\) \{[^}]*\}"#, options: .regularExpression) else {
            return XCTFail("takeScreenshot が null のときの分岐がありません")
        }
        let nullBranch = h[range]
        XCTAssertTrue(nullBranch.contains("shotFailed = true") && nullBranch.contains("break;"),
                      "撮れなかったら止めて失敗として返す形になっていません")
        XCTAssertFalse(nullBranch.contains("settled = true"), "撮れなかったのに整定したことにしている")
    }

    /// 外接矩形は止まらなかったときだけ求める(止まったときに求めると全画素の走査が毎回乗る)
    func testChangedRegionIsComputedOnlyWhenNotSettled() throws {
        let h = handler(try routerSource())
        XCTAssertTrue(h.contains("if (!settled && !shotFailed && beforeLastChange != null)"),
                      "lastChangeRegion を settled == false のときだけ求める形になっていません")
    }
}
