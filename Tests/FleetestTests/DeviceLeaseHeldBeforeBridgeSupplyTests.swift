// iOS/Android のブリッジ供給(buildIOSWorkers/buildAndroidWorkers。Wipe Data・古いブリッジ停止・
// シミュレータ起動などの破壊的操作を含み数十秒〜数分かかりうる)は、run-lease を持つ**前**に
// 走ってはいけない(2026-09-20 負荷テスト: 供給中は lease が無く `stop-device` に台を奪われ、
// ワーカーが "unreachable bridge" で離脱してシナリオが requeue された)。
//
// 前倒しは `ProfileRunner.buildWorkersWithFrontLoadedLease` の1箇所にあり、run / api run の全供給経路が
// そこを通る(通っていることは DeviceLeaseFrontLoadWiringTests が縛る)。ここはその本体の順序
// 「その時点で解決できる台の鍵を求める → reject(他プロセスの lease と衝突しないか)→ hold → 供給」を縛る。**reject は必ず hold より前**(自分の lease を自分と衝突と
// 誤診するため。RunLeaseGuardOrderingTests と同じ理由)。配線は型では守れないのでソースで固定する
// (コメント中の関数名の言及に釣られないよう、走査はコメント行を除いた本文の行番号で比べる)。

import XCTest

final class DeviceLeaseHeldBeforeBridgeSupplyTests: XCTestCase {
    private static let path = "Sources/fleetest/ProfileRunner.swift"

    /// コメント行(先頭が `//`)を除いた本文の行。SupplyLeaseHandOffWiringTests.code と同じ形
    private static func codeLines() throws -> [String] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    private func assertOrder(
        resolve: String, reject: String, hold: String, build: String,
        in lines: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard let resolveIdx = lines.firstIndex(where: { $0.contains(resolve) }) else {
            return XCTFail("lease keys must be resolved before supply (\(resolve) not found)", file: file, line: line)
        }
        guard let rejectIdx = lines.firstIndex(where: { $0.contains(reject) }) else {
            return XCTFail("planned keys must be checked against other run-leases (\(reject) not found)",
                            file: file, line: line)
        }
        guard let holdIdx = lines.firstIndex(where: { $0.contains(hold) }) else {
            return XCTFail("planned keys must be held before supply (\(hold) not found)", file: file, line: line)
        }
        guard let buildIdx = lines.firstIndex(where: { $0.contains(build) }) else {
            return XCTFail("\(build) call not found", file: file, line: line)
        }
        XCTAssertLessThan(resolveIdx, rejectIdx, "lease keys must be resolved before the reject check",
                          file: file, line: line)
        XCTAssertLessThan(rejectIdx, holdIdx, "reject must come before hold (else a self-held lease "
                          + "reads as a conflict)", file: file, line: line)
        XCTAssertLessThan(holdIdx, buildIdx, "hold must come before the bridge supply call — "
                          + "holding after supply leaves a window with no lease while the bridge is built",
                          file: file, line: line)
    }

    /// 共通関数の本体だけを切り出す(他の関数の同名の行に釣られないため)
    private static func helperBody() throws -> [String] {
        let lines = try codeLines()
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("static func buildWorkersWithFrontLoadedLease(")
        }) else { return [] }
        guard let end = lines[start...].firstIndex(where: { $0 == "return workers" }) else { return [] }
        return Array(lines[start...end])
    }

    func testFrontLoadHelperHoldsPlannedKeysBeforeBuildingWorkers() throws {
        try assertOrder(
            resolve: "let plannedKeys = leaseKeysByDevice(resolved: resolved)",
            reject: "try rejectIfDeviceLeased(devices: plannedKeys, leaseStateDir: leaseStateDir)",
            hold: "supplyLease?.hold(keys: plannedKeys.map(\\.key))",
            build: "let workers = try await build()",
            in: try Self.helperBody())
    }

    /// 供給に失敗してレーンから外れた台は lease を持ち続けない(他の run が使えなくなるのを防ぐ)
    func testUnbuiltPlannedKeysAreReleasedAfterSupply() throws {
        let body = try Self.helperBody()
        guard let buildIdx = body.firstIndex(where: { $0.contains("let workers = try await build()") }),
              let releaseIdx = body.firstIndex(where: {
                  $0.contains("supplyLease?.releaseKeys(plannedKeys.map(\\.key)")
              }) else {
            return XCTFail("the helper must release planned keys that never became a worker")
        }
        XCTAssertLessThan(buildIdx, releaseIdx)
    }
}
