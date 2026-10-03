// 2026-10-03 負荷テストの CLI ファズで見つけた文言・検査の食い違い(maintainer-notes §64.7)。
// ①--port 0 が検査を通り「接続拒否・ランナーが止まった」と案内した ②ライブ操作の自動起動が範囲外の
// ポートでブリッジを起こした(bridge up は同じポートを断る)③status 0 の「error (0)」④(udid だけの呼び出しへの別宛先の
// 拒否文)は FleetestMCPTests/RefFromAnotherTargetUDIDTests

import ArgumentParser
import FTBridgeClient
import FTCore
import XCTest
@testable import fleetest

final class MinorWordingFixes20261003Tests: XCTestCase {

    // MARK: - ① --port 0

    func testManualDriveRejectsPortZero() {
        XCTAssertThrowsError(try Snapshot.parse(["--port", "0"])) { error in
            XCTAssertTrue(Snapshot.message(for: error).contains("--port must be between 1 and 65535 (got 0)"))
        }
        XCTAssertNoThrow(try Snapshot.parse(["--port", "8123"]))
    }

    func testBridgeDownRejectsPortZero() {
        XCTAssertThrowsError(try Bridge.Down.parse(["--port", "0"]))
    }

    /// run と api run は検査規則も揃える(CLAUDE.md「2実装で検査規則を揃える」)。run-file も同じ
    func testRunEntryPointsRejectPortZero() {
        XCTAssertThrowsError(try RunScenarios.parse(["--port", "0"]))
        XCTAssertThrowsError(try ApiRunCommand.parse(["--scenario", "A.b", "--port", "0"]))
        XCTAssertThrowsError(try RunFileCommand.parse(["x.swift", "--port", "0"]))
        XCTAssertNoThrow(try ApiRunCommand.parse(["--scenario", "A.b", "--port", "8123"]))
    }

    // MARK: - ② ライブ操作の自動起動は bridge up と同じ範囲検査

    func testLiveServeWithUDIDRejectsPortOutsideTheScanRange() {
        let outside = String(BridgeDiscovery.portRange.upperBound + 16)
        XCTAssertThrowsError(try ApiLiveServe.parse(["--udid", "U", "--port", outside])) { error in
            XCTAssertTrue(ApiLiveServe.message(for: error).contains("is outside the range the bridge scanner covers"))
        }
        // udid が無い = 自動起動しない(既存のブリッジへ繋ぐだけ)ので断らない
        XCTAssertNoThrow(try ApiLiveServe.parse(["--port", outside]))
        XCTAssertNoThrow(try ApiLiveServe.parse(["--udid", "U", "--port",
                                                String(BridgeDiscovery.portRange.lowerBound)]))
    }

    // MARK: - ③ status 0 は数字を出さない

    func testBadResponseWithStatusZeroOmitsTheCode() {
        XCTAssertEqual(DriverError.badResponse(status: 0, body: "failed to open the URL").errorDescription,
                       "The driver returned an error: failed to open the URL")
        XCTAssertEqual(DriverError.badResponse(status: 500, body: "boom").errorDescription,
                       "The driver returned an error (500): boom")
    }
}
