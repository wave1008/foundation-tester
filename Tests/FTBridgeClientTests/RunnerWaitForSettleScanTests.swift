// XCUITest ランナー(Runner/FleetestRunnerUITests/BridgeRouter.swift)の POST /waitForSettle のソース走査。
//
// ランナーは Swift のテストから呼べない(XCUIScreen が要る)ので、契約の要所をソースで固定する。
// 走査はコメントを落としてから行う(判定の名前は doc コメントにも出るので、素のまま検索すると
// 配線を消してもコメントだけで通る)。契約は Sources/FTCore/BridgeDTO.swift の WaitForSettleRequest。

import XCTest

final class RunnerWaitForSettleScanTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// `//` 以降を落とした BridgeRouter.swift(`///` の doc コメントも落ちる)
    private func routerSource() throws -> String {
        let url = repoRoot.appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let range = line.range(of: "//") else { return String(line) }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }

    /// `func <name>(` の本体(最初の `{` から対応する `}` まで)。見つからなければ失敗(走査が空振りしない確認を兼ねる)
    private func functionBody(_ name: String, in source: String) throws -> String {
        guard let start = source.range(of: "func \(name)(") else {
            XCTFail("BridgeRouter.swift に func \(name)( が見つかりません")
            return ""
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else {
            XCTFail("func \(name) の本体が見つかりません")
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
        XCTFail("func \(name) の本体が閉じていません")
        return ""
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// ルートの登録が消える/ハンドラ名が変わると、ランナーは 404 を返してホストの waitForSettle が全部落ちる
    func testRouteIsRegistered() throws {
        let source = try routerSource()
        XCTAssertNotNil(
            normalized(source).range(
                of: #"case \("POST", "/waitForSettle"\): response = try handleWaitForSettle\(request\.body\)"#,
                options: .regularExpression),
            "POST /waitForSettle のルートが handle の switch にありません")
    }

    /// 操作ではないので mutatingPaths に入れない(入れると skipSettle の扱いが絡み、ハンドラ自身の settlePending と二重になる)
    func testIsNotAMutatingPath() throws {
        let source = try routerSource()
        guard let start = source.range(of: "static let mutatingPaths") else {
            return XCTFail("mutatingPaths が見つかりません")
        }
        let tail = source[start.upperBound...]
        guard let end = tail.firstIndex(of: "]") else { return XCTFail("mutatingPaths の閉じ括弧が見つかりません") }
        XCTAssertFalse(tail[..<end].contains("/waitForSettle"),
                       "/waitForSettle を mutatingPaths に入れない(操作ではない)")
    }

    /// 窓と上限は両方とも BridgeAPI の受け付け範囲で丸める(ホストの門を通らない経路の最後の砦)。
    /// 入れ替え(窓に上限の範囲)・丸め忘れ・片側だけの丸めはどれも落ちる
    func testClampsQuietAndTimeoutWithTheSharedRanges() throws {
        let source = try routerSource()
        let handler = normalized(try functionBody("handleWaitForSettle", in: source))
        XCTAssertNotNil(
            handler.range(of: #"clamped\(req\.quietMs, to: BridgeAPI\.waitForSettleQuietRangeMs\)"#,
                          options: .regularExpression),
            "quietMs を BridgeAPI.waitForSettleQuietRangeMs で丸めていません")
        XCTAssertNotNil(
            handler.range(of: #"clamped\(req\.timeoutMs, to: BridgeAPI\.waitForSettleTimeoutRangeMs\)"#,
                          options: .regularExpression),
            "timeoutMs を BridgeAPI.waitForSettleTimeoutRangeMs で丸めていません")
        let clamp = normalized(try functionBody("clamped", in: source))
        XCTAssertTrue(clamp.contains("min(max(value, range.lowerBound), range.upperBound)"),
                      "clamped が下限と上限の両方で丸めていません")
    }

    /// 比べるのは各辺を削った内側。縁のインジケータのフェード(停止の後も変わる)を拾うと、止まった画面が「動き続ける」になる
    func testComparesTheInsetRect() throws {
        let source = try routerSource()
        let pack = normalized(try functionBody("packedPixels", in: source))
        guard let inset = pack.range(of: "BridgeAPI.waitForSettleCompareRect(frame)"),
              let crop = pack.range(of: "cg.cropping(to: rect)") else {
            return XCTFail("packedPixels が BridgeAPI.waitForSettleCompareRect(frame) で削った範囲を crop していません")
        }
        XCTAssertLessThan(inset.lowerBound, crop.lowerBound, "削る前の範囲を crop している")
        XCTAssertTrue(pack.contains("inner.x * scale"), "削った範囲(inner)を px へ直して crop していません")
    }

    /// 返したあとに settlePending を立てる(直後にホストが読む木を、XCTest のキャッシュでなく取り直した木にする)。
    /// 撮影ループより後ろに置く(前に立てても読み手は同じだが、ループの途中の throw で立ったまま残る)
    func testSetsSettlePendingAfterTheCaptureLoop() throws {
        let source = try routerSource()
        let handler = normalized(try functionBody("handleWaitForSettle", in: source))
        guard let pending = handler.range(of: "settlePending = true"),
              let loop = handler.range(of: "while true") else {
            return XCTFail("handleWaitForSettle が settlePending = true を立てていません")
        }
        XCTAssertGreaterThan(pending.lowerBound, loop.lowerBound, "settlePending を撮影ループより前に立てている")
    }

    /// 1 周ごとに画像を作る常駐ループは autoreleasepool で区切る(最大 60 秒ぶんの画像が溜まる)
    func testWrapsEachCaptureInAnAutoreleasePool() throws {
        let source = try routerSource()
        let handler = normalized(try functionBody("handleWaitForSettle", in: source))
        XCTAssertNotNil(
            handler.range(of: #"autoreleasepool \{ settleFrame\("#, options: .regularExpression),
            "撮影(settleFrame)が autoreleasepool で包まれていません")
    }

    /// 外接矩形は「止まらなかった」ときだけ求める(止まったときに求めると全画素の走査が毎回乗る)
    func testComputesTheChangedRegionOnlyWhenNotSettled() throws {
        let source = try routerSource()
        let handler = normalized(try functionBody("handleWaitForSettle", in: source))
        XCTAssertNotNil(
            handler.range(of: #"if !settled, let before = beforeLastChange"#, options: .regularExpression),
            "lastChangeRegion を settled == false のときだけ求める形になっていません")
    }

    /// 画面の画素だけを見る = セッション不要。requireApp は 409 を投げ、ホストはそれを「セッション消失」と読んで activate を撃つ
    func testNeedsNoSession() throws {
        let source = try routerSource()
        let handler = try functionBody("handleWaitForSettle", in: source)
        XCTAssertFalse(handler.contains("requireApp"), "waitForSettle にセッションを要求しない")
        XCTAssertFalse(handler.contains("requireForeground"), "waitForSettle に前面アプリを要求しない")
    }
}
