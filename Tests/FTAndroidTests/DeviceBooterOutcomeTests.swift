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
            DeviceBooter.BootOutcome(name: "iPhone 17 Pro", platform: "ios", failure: nil),
            DeviceBooter.BootOutcome(name: "Pixel 9", platform: "android", failure: nil),
        ])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.succeededCount, 2)
        XCTAssertEqual(summary.failedNames, [])
        XCTAssertFalse(summary.allFailed)
    }

    /// 不具合1そのもの: 1台以上あって、1台も成功しなかったら全滅
    func testEveryDeviceFailingIsAllFailed() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([
            DeviceBooter.BootOutcome(name: "Pixel 9(Android 15)-01", platform: "android", failure: "boom"),
            DeviceBooter.BootOutcome(name: "Pixel 9(Android 15)-02", platform: "android", failure: "boom"),
        ])
        XCTAssertEqual(summary.succeededCount, 0)
        XCTAssertEqual(summary.failedNames, ["Pixel 9(Android 15)-01", "Pixel 9(Android 15)-02"])
        XCTAssertTrue(summary.allFailed)
    }

    /// 「1台の失敗で全体を落とさない」規律 —— 部分失敗は全滅ではない
    func testPartialFailureIsNotAllFailed() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([
            DeviceBooter.BootOutcome(name: "iPhone 17 Pro", platform: "ios", failure: nil),
            DeviceBooter.BootOutcome(name: "Pixel 9(Android 15)-03", platform: "android", failure: "boom"),
        ])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.succeededCount, 1)
        XCTAssertEqual(summary.failedNames, ["Pixel 9(Android 15)-03"])
        XCTAssertFalse(summary.allFailed)
    }

    /// 実害 2026-09-10 の形: 4台が同じ理由(simctl の4行のエラー)で落ちた。
    /// 全滅の1行に**理由が載り**、**同じ理由は1回だけ**・複数行は1行に畳まれる
    func testAllFailedDescriptionCarriesTheReasonOnceForIdenticalFailures() {
        let simctl = """
            simctl bootstatus: An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=401):
            The iOS 27.0 simulator runtime is not available.
            runtime path not found
            """
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize(
            ["-02", "-01", "-04", "-03"].map {
                DeviceBooter.BootOutcome(name: "iPhone 17 Pro(iOS 27.0)\($0)", platform: "ios", failure: simctl)
            })
        XCTAssertTrue(summary.allFailed)
        XCTAssertEqual(summary.failedDescription,
                       "iPhone 17 Pro(iOS 27.0)-02, iPhone 17 Pro(iOS 27.0)-01, iPhone 17 Pro(iOS 27.0)-04,"
                       + " iPhone 17 Pro(iOS 27.0)-03 — simctl bootstatus: An error was encountered processing"
                       + " the command (domain=com.apple.CoreSimulator.SimError, code=401): / The iOS 27.0"
                       + " simulator runtime is not available. / runtime path not found")
    }

    /// 理由が違う台は理由ごとに束ねる(初出順)。理由の無い失敗は名前だけ
    func testDifferentReasonsAreGroupedInFirstSeenOrder() {
        let summary = DeviceBooter.BootOutcomeSummarizer.summarize([
            DeviceBooter.BootOutcome(name: "A", platform: "ios", failure: "runtime missing"),
            DeviceBooter.BootOutcome(name: "B", platform: "android", failure: "avd not found"),
            DeviceBooter.BootOutcome(name: "C", platform: "ios", failure: "runtime missing"),
            DeviceBooter.BootOutcome(name: "D", platform: "ios", failure: nil),
            DeviceBooter.BootOutcome(name: "E", platform: "ios", failure: ""),
        ])
        XCTAssertEqual(summary.failedNames, ["A", "B", "C", "E"])
        XCTAssertEqual(summary.failedDescription, "A, C — runtime missing; B — avd not found; E")
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

/// 「すでに停止している」を停止の失敗として数えない(実害 2026-09-10)。
/// iOS は `sim.booted` の guard で成功扱いなのに、Android は serial の解決が
/// `avdNotRunning` で throw するため停止済みの台が「停止に失敗」に化け、全台停止済みの機械で
/// 一括停止が `every device failed to stop` を出していた(全滅だけを失敗と伝えるように
/// なって表面化した)。**プロファイルの誤り(avd 未記載)は失敗のまま**。
final class DeviceBooterAlreadyStoppedTests: XCTestCase {

    func testAvdNotRunningCountsAsAlreadyStopped() {
        let error = AndroidDeviceCatalogError.avdNotRunning("avd-1", running: [:])
        XCTAssertTrue(DeviceBooter.isAlreadyStopped(error),
                      "起動していない = 停止済み。停止の失敗にはしない")
    }

    func testMissingAvdInProfileIsStillAFailure() {
        let error = AndroidDeviceCatalogError.noIdentifier(name: "Pixel 9")
        XCTAssertFalse(DeviceBooter.isAlreadyStopped(error),
                       "プロファイルに avd が無いのは設定の誤り。黙って成功にしない")
    }

    func testDisconnectedPhysicalDeviceIsStillAFailure() {
        let error = AndroidDeviceCatalogError.deviceNotConnected(
            name: "Pixel 4a", serial: "SERIAL", connected: [])
        XCTAssertFalse(DeviceBooter.isAlreadyStopped(error))
    }

    func testUnrelatedErrorsAreNotAlreadyStopped() {
        struct Boom: Error {}
        XCTAssertFalse(DeviceBooter.isAlreadyStopped(Boom()))
    }
}
