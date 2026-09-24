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

/// LIVE-3: bridgeUnreachable のヒントは starter(自動起動の状態機械)の状態も加味する。
/// 実地(実機): 起動待ち中の probe が transportFailed を返し、「起動中です(自然に直ります)」の
/// 直後に「自然には直りません: bridge up してください」という矛盾した案内が出た。
/// `ApiLiveServe.BridgeUnreachableGuidance.decide` は純粋関数なのでデバイス無しで全分岐を確かめる。
/// annotated がこの結果どおりに starter/probe のどちらを使うかは
/// ApiLiveConnectionHintWiringTests(ソース走査)が縛る。
final class BridgeUnreachableGuidanceTests: XCTestCase {

    /// starter が無ければ probe の中身に関わらず probeHint のまま(従来どおり)
    func testNoStarterAlwaysKeepsTheProbeHint() {
        for probe: BridgeDiscovery.StatusProbe in [.transportFailed, .timedOut, .notBound, .answered] {
            XCTAssertEqual(
                ApiLiveServe.BridgeUnreachableGuidance.decide(
                    probe: probe, hasStarter: false, starterIsIdle: true, triggering: true),
                .probeHint, "starter が無いとき(\(probe))")
        }
    }

    /// starter が starting/failed(非 idle)なら probe の中身を問わず starter の状態を使う ——
    /// 進行中の自動起動と矛盾する案内を出さない
    func testNonIdleStarterSuppressesTheProbeHintRegardlessOfProbeOrTriggering() {
        for probe: BridgeDiscovery.StatusProbe in [.transportFailed, .timedOut, .notBound, .answered] {
            for triggering in [true, false] {
                XCTAssertEqual(
                    ApiLiveServe.BridgeUnreachableGuidance.decide(
                        probe: probe, hasStarter: true, starterIsIdle: false, triggering: triggering),
                    .useStarterSuffix, "starter が非 idle のとき(probe: \(probe), triggering: \(triggering))")
            }
        }
    }

    /// idle な starter + 能動経路(triggering) + ブリッジが消えている(transportFailed/notBound)
    /// —— bridgeConnectionRefused と同じ状況なので起動をトリガーする
    func testIdleStarterTriggeringAndBridgeGoneTriggersTheStarter() {
        for probe: BridgeDiscovery.StatusProbe in [.transportFailed, .notBound] {
            XCTAssertEqual(
                ApiLiveServe.BridgeUnreachableGuidance.decide(
                    probe: probe, hasStarter: true, starterIsIdle: true, triggering: true),
                .triggerStarter, "probe: \(probe)")
        }
    }

    /// busy(timedOut)は「待て」のまま —— idle な starter があっても起動をトリガーしない
    func testBusyStaysWaitEvenWithAnIdleStarter() {
        XCTAssertEqual(
            ApiLiveServe.BridgeUnreachableGuidance.decide(
                probe: .timedOut, hasStarter: true, starterIsIdle: true, triggering: true),
            .probeHint)
    }

    /// 追跡した瞬間に応答があった(answered)なら idle な starter があっても起動をトリガーしない
    func testAnsweredStaysProbeHintEvenWithAnIdleStarter() {
        XCTAssertEqual(
            ApiLiveServe.BridgeUnreachableGuidance.decide(
                probe: .answered, hasStarter: true, starterIsIdle: true, triggering: true),
            .probeHint)
    }

    /// 受動経路(emitFrame。triggering:false)は idle な starter + ブリッジ消失でもトリガーしない
    /// —— 起動トリガーは能動的な操作の失敗経路からだけ
    func testPassiveObservationNeverTriggersTheStarterEvenWhenIdleAndBridgeGone() {
        for probe: BridgeDiscovery.StatusProbe in [.transportFailed, .notBound] {
            XCTAssertEqual(
                ApiLiveServe.BridgeUnreachableGuidance.decide(
                    probe: probe, hasStarter: true, starterIsIdle: true, triggering: false),
                .probeHint, "probe: \(probe)")
        }
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
