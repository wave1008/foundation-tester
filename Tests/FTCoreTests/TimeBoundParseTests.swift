import XCTest
@testable import FTCore

final class TimeBoundParseTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-07-16T00:00:00Z")!

    // MARK: - 3形すべてが受理される

    func testAcceptsAbsoluteDate() {
        XCTAssertEqual(
            TimeBoundParse.parse("2026-09-01", now: now),
            ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
    }

    func testAcceptsRelativeDays() {
        XCTAssertEqual(TimeBoundParse.parse("90d", now: now), now.addingTimeInterval(-90 * 86400))
    }

    func testAcceptsRelativeHours() {
        XCTAssertEqual(TimeBoundParse.parse("2h", now: now), now.addingTimeInterval(-2 * 3600))
    }

    func testAcceptsRelativeMinutes() {
        XCTAssertEqual(TimeBoundParse.parse("30m", now: now), now.addingTimeInterval(-30 * 60))
    }

    func testAcceptsRelativeSeconds() {
        XCTAssertEqual(TimeBoundParse.parse("90s", now: now), now.addingTimeInterval(-90))
    }

    func testAcceptsFractionalDuration() {
        XCTAssertEqual(TimeBoundParse.parse("1.5h", now: now), now.addingTimeInterval(-1.5 * 3600))
    }

    func testAcceptsPrefixedEpochSeconds() {
        XCTAssertEqual(TimeBoundParse.parse("@1757280000", now: now), Date(timeIntervalSince1970: 1_757_280_000))
    }

    func testAcceptsPrefixedFractionalEpoch() {
        XCTAssertEqual(TimeBoundParse.parse("@1757280000.5", now: now), Date(timeIntervalSince1970: 1_757_280_000.5))
    }

    // MARK: - witness: 旧実装が拒否していた形が今は通る

    /// 旧 RunResultsQuery.parseSince(fleetest results / api results が使う)は
    /// "YYYY-MM-DD" と "<num>d"/"<num>h" のみを受理し、"m"/"s" 単位を拒否していた
    func testRunResultsQueryNowAcceptsMinutesAndSeconds() {
        XCTAssertNotNil(RunResultsQuery.parseSince("30m", referenceDate: now))
        XCTAssertNotNil(RunResultsQuery.parseSince("90s", referenceDate: now))
    }

    /// 旧 host-metrics-summary の --since/--until 解釈(現在は fleetest 側から
    /// TimeBoundParse.parse を直接呼ぶ。FTCoreTests は fleetest モジュールに依存しないため
    /// コマンド型は直接は呼べないが、判定の実装はここに一本化されているので確認になる)は
    /// "<num>[smhd]" と epoch のみを受理し、"YYYY-MM-DD" を拒否していた
    func testHostMetricsSummaryNowAcceptsAbsoluteDate() {
        XCTAssertEqual(
            TimeBoundParse.parse("2026-09-01", now: now),
            ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
    }

    // MARK: - 不正な形は nil

    func testRejectsInvalidFormats() {
        // "@nan"/"@inf" は Double() が成功するので、isFinite の門が外れると素通りする
        for raw in ["", "abc", "0d", "-3h", "2026-13-99", "10x", "1757280000", "@abc", "@nan", "@inf"] {
            XCTAssertNil(TimeBoundParse.parse(raw, now: now), "\(raw) は不正として nil を返すべきです")
        }
    }

    /// witness: 裸の数値(接頭辞なし)は epoch として読まない。読んでしまうと "30d" と打つはずが
    /// "30" になったタイポが「エラー」ではなく「epoch 30 ≈ 1970年 = 実質全期間」として
    /// 黙って成功してしまう(このリポジトリが今回潰した「指定したのに黙って効かない/誤る」形)
    func testBareNumberIsRejectedSoA30dTypoDoesNotSilentlyMatchEverything() {
        XCTAssertNil(TimeBoundParse.parse("30", now: now))
    }

    // MARK: - 相対期間の計算が now から正しく引かれている

    func testRelativeDurationSubtractsFromNow() {
        XCTAssertEqual(TimeBoundParse.parse("90d", now: now), now.addingTimeInterval(-90 * 86400))
    }
}
