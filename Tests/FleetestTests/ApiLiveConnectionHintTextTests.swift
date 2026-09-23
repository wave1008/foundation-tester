import XCTest
import FTBridgeClient
@testable import fleetest

/// LIVE-1/LIVE-2: ライブ操作の失敗ヒントの文言選択(純粋関数だけ)。判定そのもの
/// (BridgeDiscovery.probeStatus の4値・DriverError.isNoReadableWindow)は FTBridgeClient/FTCore
/// 側のテストが固定するので、ここは「状態ごとに違う文言を返すか」「固まりと busy の対処が
/// 逆になっているか」だけを確かめる。annotated がこれらを実際に呼んでいるかは
/// ApiLiveConnectionHintWiringTests(ソース走査)が縛る。
final class ApiLiveConnectionHintTextTests: XCTestCase {

    // MARK: - bridgeUnreachableHint(固まり vs busy)

    /// 固まり(transportFailed): 建て直しが要る。「busy」「待て」だけで済ませない
    func testTransportFailedPointsAtRebuildingNotWaiting() {
        let hint = ApiLiveServe.bridgeUnreachableHint(probe: .transportFailed)
        XCTAssertTrue(hint.contains("gone"), hint)
        XCTAssertTrue(hint.contains("fleetest bridge up"), hint)
        XCTAssertFalse(hint.lowercased().contains("busy"),
                       "固まりを busy と呼ぶと『待てば直る』に読める — 過去の取り違え(§44.1)と同じ形")
    }

    /// busy(timedOut): 待てば直る。建て直しを勧めない
    func testTimedOutPointsAtWaitingNotRebuilding() {
        let hint = ApiLiveServe.bridgeUnreachableHint(probe: .timedOut)
        XCTAssertTrue(hint.lowercased().contains("busy"), hint)
        XCTAssertFalse(hint.contains("fleetest bridge up"),
                       "busy なだけの接続を固まりと同じ『建て直せ』にしない")
    }

    /// 誰も listen していない(probe 時点で消えていた): 固まりと同じく建て直しを勧める
    func testNotBoundAlsoPointsAtRebuilding() {
        let hint = ApiLiveServe.bridgeUnreachableHint(probe: .notBound)
        XCTAssertTrue(hint.contains("fleetest bridge up"), hint)
    }

    /// 追跡した瞬間には応答した(元の失敗は一過性だった可能性): 建て直しも待機も強要しない
    func testAnsweredMarksTheOriginalFailureAsTransient() {
        let hint = ApiLiveServe.bridgeUnreachableHint(probe: .answered)
        XCTAssertTrue(hint.lowercased().contains("transient"), hint)
        XCTAssertFalse(hint.contains("fleetest bridge up"), hint)
    }

    /// 4状態それぞれ違う文言を返すこと(丸めて同じ文言に潰すと状態を見分けた意味が無い)
    func testAllFourProbeStatesProduceDistinctText() {
        let hints: Set<String> = [
            ApiLiveServe.bridgeUnreachableHint(probe: .transportFailed),
            ApiLiveServe.bridgeUnreachableHint(probe: .timedOut),
            ApiLiveServe.bridgeUnreachableHint(probe: .notBound),
            ApiLiveServe.bridgeUnreachableHint(probe: .answered),
        ]
        XCTAssertEqual(hints.count, 4)
    }

    // MARK: - noReadableWindowHint(Android の 422)

    func testNoReadableWindowHintExplainsItIsTransientAndSelfClearing() {
        let hint = ApiLiveServe.noReadableWindowHint
        XCTAssertTrue(hint.contains("13-37s"), hint)
        XCTAssertTrue(hint.contains("not"), hint)
        XCTAssertTrue(hint.lowercased().contains("foreground"), hint)
    }
}

/// a11y サーバの一時的な停止(500 + kAXErrorAPIDisabled)の出口。
/// run は同じ判定で結果を捨てて振り直すが、MCP とライブ操作は人・エージェントが次の一手を
/// 打つ場なので**環境要因であることと「待って再試行」**を言う(実地 2026-09-23 の負荷テスト:
/// 生の `Error Domain=com.apple.dt.xctest.automation-support.error Code=8 …` だけが返っていた)。
final class ApiLiveAccessibilityOutageHintTests: XCTestCase {

    func testHintSaysItIsAnEnvironmentFaultAndToWait() {
        let hint = ApiLiveServe.accessibilityOutageHint
        XCTAssertTrue(hint.contains("environment"), hint)
        XCTAssertTrue(hint.lowercased().contains("wait"), hint)
        // **アプリの不具合と読ませない**(run の分類と同じ立場)
        XCTAssertTrue(hint.contains("not a"), hint)
    }

    /// 判定は共有・文言は呼び手ごと: MCP の文言をそのまま写していない
    func testWordingIsNotTheMCPOne() {
        XCTAssertFalse(ApiLiveServe.accessibilityOutageHint.contains("ft_"),
                       "ライブ操作の文言に MCP のツール名を混ぜない")
    }
}
