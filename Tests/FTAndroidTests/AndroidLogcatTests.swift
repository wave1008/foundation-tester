// AndroidLogcat.filter の純粋ロジック(パッケージ絞り込み・末尾 maxLines への切り詰め)。
// adb は叩かない(デバイス不要)。logcatTimeArgument は書式の固定だけ確認する。

import XCTest
@testable import FTAndroid

final class AndroidLogcatTests: XCTestCase {

    private let sample = """
        08-09 10:00:00.100  1234  1234 I ActivityManager: Start proc com.example.other for broadcast
        08-09 10:00:00.200  5678  5678 D com.ftester.e2e.android: onCreate
        08-09 10:00:00.300  5678  5679 E AndroidRuntime: FATAL EXCEPTION: main
        08-09 10:00:00.400  5678  5679 E AndroidRuntime: Process: com.ftester.e2e.android, PID: 5678
        08-09 10:00:00.500  9999  9999 I OtherApp: unrelated line
        """

    // MARK: - packageName 絞り込み

    func testFilterKeepsOnlyLinesContainingPackageName() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: "com.ftester.e2e.android",
                                          maxLines: 0)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.contains("com.ftester.e2e.android") })
    }

    /// **テキスト一致はクラッシュの原因行を落とす**: `FATAL EXCEPTION` とスタックトレースは
    /// パッケージ名を含まず、名指しで残るのは `Process:` の1行だけ。だから recent() は
    /// crash バッファではこの絞り込みを使わない(AndroidLogcat.recent のコメント参照)。
    /// この性質が変わったら上の判断の前提が崩れるので、ここで固定する
    func testFilterDropsTheCrashReasonLine() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: "com.ftester.e2e.android",
                                          maxLines: 0)
        XCTAssertFalse(result.contains { $0.contains("FATAL EXCEPTION") })
    }

    /// 一致するパッケージが無ければ空配列(黙って全件を返さない = 絞り込みが実際に効いていること)
    func testFilterWithNoMatchingLinesReturnsEmpty() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: "com.nonexistent.app",
                                          maxLines: 0)
        XCTAssertEqual(result, [])
    }

    func testFilterWithNilPackageNameReturnsAllLines() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: nil, maxLines: 0)
        XCTAssertEqual(result.count, 5)
    }

    /// 空文字は「絞り込み無し」として扱う(呼び出し側が未指定を "" で渡す経路の保険)
    func testFilterWithEmptyPackageNameReturnsAllLines() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: "", maxLines: 0)
        XCTAssertEqual(result.count, 5)
    }

    // MARK: - maxLines への切り詰め

    func testFilterTruncatesToTailMaxLines() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: nil, maxLines: 2)
        XCTAssertEqual(result.count, 2)
        // 末尾2行そのもの(先頭3行を落とし、末尾は落とさない)であることを確認
        XCTAssertTrue(result[0].contains("PID: 5678"), result[0])
        XCTAssertTrue(result[1].contains("OtherApp"), result[1])
    }

    /// maxLines <= 0 は「切り詰めない」の契約
    func testFilterWithZeroOrNegativeMaxLinesDoesNotTruncate() {
        XCTAssertEqual(AndroidLogcat.filter(rawOutput: sample, packageName: nil, maxLines: 0).count, 5)
        XCTAssertEqual(AndroidLogcat.filter(rawOutput: sample, packageName: nil, maxLines: -1).count, 5)
    }

    /// maxLines が実際の行数以上なら何も落とさない
    func testFilterWithMaxLinesLargerThanInputReturnsAllLines() {
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: nil, maxLines: 100)
        XCTAssertEqual(result.count, 5)
    }

    func testFilterCombinesPackageAndMaxLines() {
        // com.ftester.e2e.android の行は3つ、末尾1つだけに絞る
        let result = AndroidLogcat.filter(rawOutput: sample, packageName: "com.ftester.e2e.android",
                                          maxLines: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].contains("PID: 5678"))
    }

    // MARK: - 空入力

    func testFilterOnEmptyInputReturnsEmptyArray() {
        XCTAssertEqual(AndroidLogcat.filter(rawOutput: "", packageName: nil, maxLines: 10), [])
        XCTAssertEqual(AndroidLogcat.filter(rawOutput: "", packageName: "com.example", maxLines: 10), [])
    }

    /// 空行だけの入力も空配列(omittingEmptySubsequences の契約確認)
    func testFilterOnBlankLinesOnlyReturnsEmptyArray() {
        XCTAssertEqual(AndroidLogcat.filter(rawOutput: "\n\n\n", packageName: nil, maxLines: 10), [])
    }

    // MARK: - logcatTimeArgument

    /// -t の書式固定("MM-dd HH:mm:ss.SSS")。書式が崩れると adb logcat -t が解釈できず
    /// エラーで落ちる(サイレントに全件フォールバックにはならない)ため、書式そのものを固定する
    func testLogcatTimeArgumentFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 9
        components.hour = 12; components.minute = 34; components.second = 56
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: components)!

        let arg = AndroidLogcat.logcatTimeArgument(secondsAgo: 0, now: now)
        XCTAssertEqual(arg.count, "MM-dd HH:mm:ss.SSS".count)
        XCTAssertTrue(arg.contains(":"))
    }

    /// secondsAgo だけ過去に戻ること(丸めや符号の反転が無いこと)
    func testLogcatTimeArgumentSubtractsSecondsAgo() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 9,
                                                      hour: 12, minute: 0, second: 30))!
        let arg = AndroidLogcat.logcatTimeArgument(secondsAgo: 30, now: now)
        XCTAssertTrue(arg.contains("12:00:00"), arg)
    }
}
