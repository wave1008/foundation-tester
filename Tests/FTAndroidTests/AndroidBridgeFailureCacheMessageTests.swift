// 失敗キャッシュ(.unavailable / unavailableRetryInterval)を再生したときの文言。
//
// 再生された文はライブの失敗と1バイトも違わなかったため、読み手は「今まさに adb forward が
// 落ちた」と読む。実際、手で `adb forward` を打って成功し `fleetest bridge status` も通るのに
// MCP だけが同じ文言を返し続ける状況で、原因をブリッジ側だと誤認して調査に数分溶かした。
// キャッシュ自体は嵐防止として残す価値がある(失敗1回は probe 2s + 起動待ち最大 10s)ので、
// 消さずに「これは再生である」と残り時間・抜け道を添える。

import XCTest
import FTCore
@testable import FTAndroid

final class AndroidBridgeFailureCacheMessageTests: XCTestCase {

    private func message(_ error: DriverError) -> String {
        error.errorDescription ?? "\(error)"
    }

    /// キャッシュの断り(`[cached: …]`)だけを切り出す。**全文で assert しない** ——
    /// 素の案内文にも `fleetest bridge up --platform android` は含まれるので、全文照合だと
    /// 断り側からその一文が消えても緑のまま通る(変異テストで実際に生き残った)
    private func cachedClause(_ text: String) -> String? {
        guard let start = text.range(of: "[cached:") else { return nil }
        return String(text[start.lowerBound...])
    }

    /// ライブの失敗は従来どおり(キャッシュの断りが付かない)
    func testLiveFailureIsNotLabelledAsCached() {
        let text = message(AndroidDriver.unreachableError(detail: "adb forward failed",
                                                           physicalDevice: false))
        XCTAssertTrue(text.contains("adb forward failed"), text)
        XCTAssertFalse(text.contains("cached"),
                       "ライブの失敗にキャッシュの断りが付いた: \(text)")
    }

    /// 再生は「再生である」と名乗り、原因(初回の detail)は引き継ぐ
    func testCachedReplayNamesItselfAndKeepsTheOriginalCause() {
        let text = message(AndroidDriver.unreachableError(
            detail: "adb forward failed: adb: device offline", physicalDevice: false,
            cachedSecondsRemaining: 42))
        XCTAssertTrue(text.contains("cached"), text)
        XCTAssertTrue(text.contains("adb forward failed: adb: device offline"),
                      "初回の原因が落ちている: \(text)")
    }

    /// **残り時間を出す** —— 「待てば直る」のか「環境を直すべき」なのかが読み手の次の一手を変える
    func testCachedReplayStatesHowLongUntilTheNextRealAttempt() {
        let text = message(AndroidDriver.unreachableError(detail: nil, physicalDevice: false,
                                                           cachedSecondsRemaining: 42))
        XCTAssertTrue(text.contains("42s"), text)
    }

    /// 端数は切り上げる。**0s とは言わない** —— 0 は「もう再試行される」と読めるが、
    /// この文が出ている以上まだ期限内なので、待っても無駄だと誤読させる
    func testSubSecondRemainderIsRoundedUpAndNeverZero() {
        let text = message(AndroidDriver.unreachableError(detail: nil, physicalDevice: false,
                                                           cachedSecondsRemaining: 0.2))
        XCTAssertTrue(text.contains("1s"), text)
        XCTAssertFalse(text.contains("0s"), text)
    }

    /// **「今すぐ直せる」と言わない**(2026-08-13 のレビュー指摘)。`.unavailable` はプロセスごとの
    /// static なので、CLI の `bridge up` が成功しても**この長寿命プロセスの記憶は消えない**。
    /// 「すぐ再試行できる」と書くと、直したのに同じ文が返る次の混乱を作る
    func testCachedReplaySaysFixingTheDeviceDoesNotClearIt() {
        let text = message(AndroidDriver.unreachableError(detail: nil, physicalDevice: false,
                                                           cachedSecondsRemaining: 5))
        guard let clause = cachedClause(text) else {
            return XCTFail("キャッシュの断りが出ていない: \(text)")
        }
        XCTAssertTrue(clause.contains("does NOT"),
                      "他プロセスで直しても消えないことを言っていない: \(clause)")
        XCTAssertTrue(clause.contains("per-process"), clause)
        XCTAssertFalse(clause.contains("retries immediately"),
                       "この文言はプロセスを跨いで効くと誤読させる: \(clause)")
    }

    /// **二重包み防止(3)の本体**: `ensureBridge()` パイプラインが使う `rawFailureDetail` は、
    /// DriverError から「まだ組み立てていない一次情報」だけを取り出す(`.errorDescription` を
    /// 経由しない)。2026-09-16 に実際に踏んだ二重包みは、この抽出をせず `.errorDescription`
    /// (固定文つきの完成文)をそのまま次の呼び出しの `detail` へ流していたのが原因 ——
    /// `unreachableError` が組み立てる `.bridgeUnreachable` の**保存側の `detail` は
    /// 常に生のまま**(固定文は `errorDescription` が読まれた瞬間にしか乗らない)ことを固定する
    func testRawFailureDetailExtractsTheStoredDetailNotTheRenderedDescription() {
        let original = AndroidDriver.unreachableError(detail: "adb forward failed: adb: device offline",
                                                       physicalDevice: false)
        XCTAssertTrue((original.errorDescription ?? "").contains("Cannot reach the driver"),
                      "前提が崩れている(errorDescription に固定文が無い): \(String(describing: original.errorDescription))")
        XCTAssertEqual(AndroidDriver.rawFailureDetail(original), "adb forward failed: adb: device offline")
    }

    /// 上の抽出を経由すれば、**実際のキャッシュ再生パイプラインでも固定文は1回しか出ない**
    /// (`ensureBridge()` の catch → `.unavailable` へ格納 → 期限内の再生、という実経路を模す)
    func testCachedReplayThroughTheRealPipelineNeverDoubleWraps() {
        let firstFailure = AndroidDriver.unreachableError(detail: "adb forward failed: adb: device offline",
                                                           physicalDevice: false)
        let raw = AndroidDriver.rawFailureDetail(firstFailure)
        let replayed = AndroidDriver.unreachableError(detail: raw, physicalDevice: false,
                                                       cachedSecondsRemaining: 42)
        let text = message(replayed)
        let occurrences = text.components(separatedBy: "Cannot reach the driver").count - 1
        XCTAssertEqual(occurrences, 1, "固定文が複数回出た(二重包み): \(text)")
        XCTAssertTrue(text.contains("adb forward failed: adb: device offline"), text)
    }
}
