import XCTest

/// api live serve の失敗ヒントの配線(LIVE-1/LIVE-2)。annotated が実際にこれらの判定を呼び、
/// bridgeUnreachable のヒントを iOS xcuitest だけに絞っていることをソース走査で縛る
/// (device が要る箇所は annotated 自体を直接呼べないため、ライブ操作の他の配線テストと同じ
/// ソース走査の流儀に合わせる)。文言そのものは ApiLiveConnectionHintTextTests が確かめる。
final class ApiLiveConnectionHintWiringTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func annotatedRange(_ code: String) throws -> Range<String.Index> {
        guard let range = code.range(of: "private func annotated(") else {
            throw XCTSkip("annotated が見当たらない — テストを見直すこと")
        }
        return range
    }

    /// bridgeConnectionRefused は従来どおり最初に判定すること(自動起動のトリガーを壊さない)
    func testBridgeConnectionRefusedIsStillCheckedFirst() throws {
        let code = try source()
        let start = try annotatedRange(code)
        guard let refusedRange = code.range(
            of: "case DriverError.bridgeConnectionRefused = error",
            range: start.upperBound..<code.endIndex) else {
            return XCTFail("bridgeConnectionRefused の既存分岐が消えている"
                + "(自動起動の noteConnectionRefused/statusSuffix はここでだけ効く)")
        }
        guard let noReadableRange = code.range(
            of: "DriverError.isNoReadableWindow(error)", range: start.upperBound..<code.endIndex)
        else {
            return XCTFail("isNoReadableWindow の分岐が annotated に無い")
        }
        XCTAssertTrue(refusedRange.upperBound < noReadableRange.lowerBound,
                      "bridgeConnectionRefused は isNoReadableWindow より前で判定すること")
    }

    /// LIVE-2: Android の 422(no-active-window-root)にヒントが付くこと
    func testAnnotatedAppendsTheNoReadableWindowHint() throws {
        let code = try source()
        let start = try annotatedRange(code)
        guard let checkRange = code.range(
            of: "DriverError.isNoReadableWindow(error)", range: start.upperBound..<code.endIndex)
        else {
            return XCTFail("annotated が Android の 422(no-active-window-root)を見ていない")
        }
        guard let hintRange = code.range(
            of: "Self.noReadableWindowHint", range: checkRange.upperBound..<code.endIndex) else {
            return XCTFail("isNoReadableWindow が真のときのヒント(noReadableWindowHint)が"
                + " 連結されていない")
        }
        XCTAssertTrue(checkRange.upperBound < hintRange.lowerBound)
    }

    /// LIVE-1: bridgeUnreachable のヒントは iOS xcuitest だけに絞り、probeStatus の結果を
    /// bridgeUnreachableHint へ渡すこと
    func testAnnotatedProbesOnlyForIOSXCUITestBridgeUnreachable() throws {
        let code = try source()
        let start = try annotatedRange(code)
        guard let caseRange = code.range(
            of: "case DriverError.bridgeUnreachable(let context, _) = error,"
                + " context.engine == .iosXCUITest",
            range: start.upperBound..<code.endIndex) else {
            return XCTFail("bridgeUnreachable のヒントは iOS xcuitest だけに絞ること"
                + "(in-app/hybrid は前面から外れて応答しないだけのことが多く、Android には"
                + " BridgeDiscovery の判定材料[isBound]がそもそも合わない)")
        }
        guard let probeRange = code.range(
            of: "BridgeDiscovery.probeStatus(port: port", range: caseRange.upperBound..<code.endIndex)
        else {
            return XCTFail("固まり(transportFailed)と busy(timedOut)を見分ける"
                + " BridgeDiscovery.probeStatus を撃っていない")
        }
        guard let hintRange = code.range(
            of: "Self.bridgeUnreachableHint(probe: probe)", range: probeRange.upperBound..<code.endIndex)
        else {
            return XCTFail("probeStatus の結果を文言選択(bridgeUnreachableHint)へ渡していない")
        }
        XCTAssertTrue(caseRange.upperBound < probeRange.lowerBound)
        XCTAssertTrue(probeRange.upperBound < hintRange.lowerBound)
    }

    /// **成功パスへ往復を足さない**: BridgeDiscovery.probeStatus の呼び出しはファイル全体で
    /// ちょうど1箇所(annotated の失敗パス)だけであること。emitObservation/emitFrame の
    /// 成功枝(catch の外)に漏れていれば、毎回の観測が毎回1往復増えることになる
    func testProbeStatusIsCalledFromExactlyOnePlace() throws {
        let code = try source()
        let occurrences = code.components(separatedBy: "BridgeDiscovery.probeStatus(").count - 1
        XCTAssertEqual(occurrences, 1,
                       "BridgeDiscovery.probeStatus の呼び出しが1箇所(annotated)だけであること"
                       + " —— 増えていたら成功パスへ漏れていないか確認すること")
    }
}
