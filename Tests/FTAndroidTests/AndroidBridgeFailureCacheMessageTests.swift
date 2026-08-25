// 失敗キャッシュ(.unavailable / unavailableRetryInterval)を再生したときの文言。
//
// 再生された文はライブの失敗と1バイトも違わなかったため、読み手は「今まさに adb forward が
// 落ちた」と読む。実際、手で `adb forward` を打って成功し `ftester bridge status` も通るのに
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
    /// 素の案内文にも `ftester bridge up --platform android` は含まれるので、全文照合だと
    /// 断り側からその一文が消えても緑のまま通る(変異テストで実際に生き残った)
    private func cachedClause(_ text: String) -> String? {
        guard let start = text.range(of: "[cached:") else { return nil }
        return String(text[start.lowerBound...])
    }

    /// ライブの失敗は従来どおり(キャッシュの断りが付かない)
    func testLiveFailureIsNotLabelledAsCached() {
        let text = message(AndroidDriver.unreachableError(detail: "adb forward failed"))
        XCTAssertTrue(text.contains("adb forward failed"), text)
        XCTAssertFalse(text.contains("cached"),
                       "ライブの失敗にキャッシュの断りが付いた: \(text)")
    }

    /// 再生は「再生である」と名乗り、原因(初回の detail)は引き継ぐ
    func testCachedReplayNamesItselfAndKeepsTheOriginalCause() {
        let text = message(AndroidDriver.unreachableError(
            detail: "adb forward failed: adb: device offline", cachedSecondsRemaining: 42))
        XCTAssertTrue(text.contains("cached"), text)
        XCTAssertTrue(text.contains("adb forward failed: adb: device offline"),
                      "初回の原因が落ちている: \(text)")
    }

    /// **残り時間を出す** —— 「待てば直る」のか「環境を直すべき」なのかが読み手の次の一手を変える
    func testCachedReplayStatesHowLongUntilTheNextRealAttempt() {
        let text = message(AndroidDriver.unreachableError(detail: nil, cachedSecondsRemaining: 42))
        XCTAssertTrue(text.contains("42s"), text)
    }

    /// 端数は切り上げる。**0s とは言わない** —— 0 は「もう再試行される」と読めるが、
    /// この文が出ている以上まだ期限内なので、待っても無駄だと誤読させる
    func testSubSecondRemainderIsRoundedUpAndNeverZero() {
        let text = message(AndroidDriver.unreachableError(detail: nil, cachedSecondsRemaining: 0.2))
        XCTAssertTrue(text.contains("1s"), text)
        XCTAssertFalse(text.contains("0s"), text)
    }

    /// **「今すぐ直せる」と言わない**(2026-08-13 のレビュー指摘)。`.unavailable` はプロセスごとの
    /// static なので、CLI の `bridge up` が成功しても**この長寿命プロセスの記憶は消えない**。
    /// 「すぐ再試行できる」と書くと、直したのに同じ文が返る次の混乱を作る
    func testCachedReplaySaysFixingTheDeviceDoesNotClearIt() {
        let text = message(AndroidDriver.unreachableError(detail: nil, cachedSecondsRemaining: 5))
        guard let clause = cachedClause(text) else {
            return XCTFail("キャッシュの断りが出ていない: \(text)")
        }
        XCTAssertTrue(clause.contains("does NOT"),
                      "他プロセスで直しても消えないことを言っていない: \(clause)")
        XCTAssertTrue(clause.contains("per-process"), clause)
        XCTAssertFalse(clause.contains("retries immediately"),
                       "この文言はプロセスを跨いで効くと誤読させる: \(clause)")
    }
}
