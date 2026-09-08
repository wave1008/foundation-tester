// 2026-09-08 耐久テストで見つかった2件の不具合を守るテスト(デバイス実体には触れない。
// 純粋関数のみ)。
// 不具合1: 1台も起動できなくても exit 0 で ✅ と言っていた —— DeviceBooter.BootOutcomeSummarizer
//   が「全滅か・部分失敗か」を要約し、CLI/API 側が exit code を決める。
// 不具合2: stale な hardware-qemu.ini.lock でレーンが恒久的に死に、エラー文言も
//   「AVD 名を確認しろ」と誤誘導していた —— DeviceBooter.fatalLines がログ本文から根因の行を拾い、
//   DeviceBooter.StaleAVDLock.shouldRetry が「消して撃ち直してよいか」を判定する。

import XCTest
@testable import FTAndroid

final class BootOutcomeSummarizerTests: XCTestCase {

    func testNoDevicesIsNotAllFailed() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([])
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.succeededCount, 0)
        XCTAssertEqual(summary.failedNames, [])
        XCTAssertFalse(summary.allFailed, "1台も対象が無いのを「全滅」にすると、プロファイルが" +
                        "空のときまで exit 1 になる")
    }

    func testAllSucceededIsNotAllFailed() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([
            DeviceBooter.BootOutcome(name: "iPhone 17 Pro", platform: "ios", succeeded: true),
            DeviceBooter.BootOutcome(name: "Pixel 9", platform: "android", succeeded: true),
        ])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.succeededCount, 2)
        XCTAssertEqual(summary.failedNames, [])
        XCTAssertFalse(summary.allFailed)
    }

    /// 不具合1そのもの: 1台以上あって、1台も成功しなかったら全滅
    func testEveryDeviceFailingIsAllFailed() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([
            DeviceBooter.BootOutcome(name: "Pixel 9(Android 15)-01", platform: "android", succeeded: false),
            DeviceBooter.BootOutcome(name: "Pixel 9(Android 15)-02", platform: "android", succeeded: false),
        ])
        XCTAssertEqual(summary.succeededCount, 0)
        XCTAssertEqual(summary.failedNames, ["Pixel 9(Android 15)-01", "Pixel 9(Android 15)-02"])
        XCTAssertTrue(summary.allFailed)
    }

    /// 「1台の失敗で全体を落とさない」規律 —— 部分失敗は全滅ではない
    func testPartialFailureIsNotAllFailed() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([
            DeviceBooter.BootOutcome(name: "iPhone 17 Pro", platform: "ios", succeeded: true),
            DeviceBooter.BootOutcome(name: "Pixel 9(Android 15)-03", platform: "android", succeeded: false),
        ])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertEqual(summary.failedNames, ["Pixel 9(Android 15)-03"])
        XCTAssertFalse(summary.allFailed)
    }
}

final class DeviceBooterFatalLinesTests: XCTestCase {

    /// 実測ログ(2026-09-08 耐久テスト)の再現。「AVD 名を確認しろ」の誤誘導の代わりに、
    /// emulator 自身が言っている理由(多重起動)をエラーメッセージへ載せられるようにする
    func testFindsTheFatalLineFromTheRealWorldLog() {
        let log = """
        === 2026-09-08T03:00:00Z emulator -avd Pixel_9_Android_15_-03 -no-snapshot -no-window
        INFO    | Storing crashdata in temporary file
        FATAL   | Running multiple emulators with the same AVD is an experimental feature.Please use -read-only flag to enable this feature.
        """
        XCTAssertEqual(DeviceBooter.fatalLines(in: log), [
            "FATAL   | Running multiple emulators with the same AVD is an experimental feature.Please use -read-only flag to enable this feature.",
        ])
    }

    func testEmptyLogYieldsNoLines() {
        XCTAssertEqual(DeviceBooter.fatalLines(in: ""), [])
    }

    func testIgnoresLinesWithoutFatalOrError() {
        let log = "INFO    | booting\nWARNING | slow disk\n"
        XCTAssertEqual(DeviceBooter.fatalLines(in: log), [])
    }

    /// 拾いすぎない(呼び出し側のエラーメッセージが肥大しないよう既定3行までに切る)
    func testCapsAtTheGivenLimit() {
        let log = (1...5).map { "ERROR | line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(DeviceBooter.fatalLines(in: log, limit: 2), ["ERROR | line 4", "ERROR | line 5"])
    }
}

final class StaleAVDLockTests: XCTestCase {

    /// 不具合2の核心: ログが多重起動を示し、かつその AVD を握る実プロセスが1つも無いときだけ
    /// 消してよい
    func testRetriesWhenLogIndicatesMultiInstanceAndNoProcessHoldsTheAVD() {
        XCTAssertTrue(DeviceBooter.StaleAVDLock.shouldRetry(
            logTail: ["FATAL | Running multiple emulators with the same AVD is an experimental feature."],
            avdProcessRunning: false))
    }

    /// **生きているプロセスのロックは絶対に消さない** —— pid 再利用で壊れた実例と同じ形の再発防止
    func testNeverRetriesWhenAnEmulatorProcessIsActuallyRunning() {
        XCTAssertFalse(DeviceBooter.StaleAVDLock.shouldRetry(
            logTail: ["FATAL | Running multiple emulators with the same AVD is an experimental feature."],
            avdProcessRunning: true))
    }

    /// 原因不明の早期終了(AVD 名の誤り等)まで自己修復に倒さない
    func testDoesNotRetryWhenTheLogDoesNotMentionMultiInstance() {
        XCTAssertFalse(DeviceBooter.StaleAVDLock.shouldRetry(
            logTail: ["FATAL | invalid AVD name"], avdProcessRunning: false))
        XCTAssertFalse(DeviceBooter.StaleAVDLock.shouldRetry(logTail: [], avdProcessRunning: false))
    }
}
