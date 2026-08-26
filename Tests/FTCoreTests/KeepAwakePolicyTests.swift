// 実機の自動ロック抑止の on/off(KeepAwakePolicy)。**"0" だけが off** で、未設定・空・その他は
// 既定(抑制する)のまま —— 拡張が渡す値(vscode-fleetest/src/spawnEnv.ts)と食い違うと、
// チェックを外しても実機は起こされ続ける(気付けるのは実機を放置したときだけ)。

import XCTest
@testable import FTCore

final class KeepAwakePolicyTests: XCTestCase {

    /// 環境変数はプロセス全体の状態なので、必ず元へ戻す(この鍵を読むのはここだけ)
    private func withEnv(_ value: String?, _ body: () -> Void) {
        let key = KeepAwakePolicy.envKey
        let saved = ProcessInfo.processInfo.environment[key]
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
        body()
        if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
    }

    func testDefaultSuppresses() {
        withEnv(nil) { XCTAssertTrue(KeepAwakePolicy.suppressesAutoLock) }
    }

    func testOnlyZeroTurnsItOff() {
        withEnv("0") { XCTAssertFalse(KeepAwakePolicy.suppressesAutoLock) }
        for value in ["1", "", "false", "no", "true"] {
            withEnv(value) {
                XCTAssertTrue(KeepAwakePolicy.suppressesAutoLock,
                              "\"\(value)\" を off と読んではいけない(off は \"0\" だけ)")
            }
        }
    }

    /// ランナーへ渡す鍵の一覧に、抑止本体と玉の選択が両方載っていること
    func testForwardedKeysCoverBothKnobs() {
        XCTAssertEqual(KeepAwakePolicy.forwardedEnvKeys,
                       [KeepAwakePolicy.envKey, KeepAwakePolicy.pulseEnvKey])
    }

    /// **Android の消灯抑止がノブに従っていること**をソースで固定する(実機が要るので実行では
    /// 確かめられない)。無条件 `stayon true` に戻ると、切っても端末が一生消灯しなくなる
    func testAndroidStayOnFollowsThePolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/FTAndroid/AndroidPhysicalDevice.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("KeepAwakePolicy.suppressesAutoLock"),
                      "Android の run 前準備がノブを読んでいない")
        XCTAssertTrue(source.contains("suppress ? \"true\" : \"false\""),
                      "off のときに stayon を戻していない(ツールが立てた消灯抑止が端末に残る)")
        XCTAssertFalse(source.contains("\"stayon\", \"true\""),
                       "stayon を無条件で立てている箇所が残っている")
    }
}
