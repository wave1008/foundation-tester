// SimulatorRuntimeFingerprint の規則(remote status の RUNTIME 欄)。
// 入力は 2026-09-10 に3台で採った `simctl list runtimes` の実物の形。
// 守るもの: ①正式版があれば正式版だけ(ベータが同居しても起動に使われるのは正式版)
// ②正式版が無ければ `(beta)` 付き(= M1Max が起動できなかった形。手元と違う文字列になること)
// ③SDK と別の版のランタイムは数えない ④使えないと申告された行は数えない

import XCTest
@testable import FTCore

final class SimulatorRuntimeFingerprintTests: XCTestCase {

    private let header = "== Runtimes =="

    private func line(_ version: String, _ build: String, suffix: String = "") -> String {
        let id = "iOS-" + version.replacingOccurrences(of: ".", with: "-")
        return "iOS \(version) (\(version) - \(build)) - com.apple.CoreSimulator.SimRuntime.\(id)\(suffix)"
    }

    /// 手元(正式版だけ)
    func testReleaseOnly() {
        let list = [header, line("26.2", "23C54"), line("27.0", "24A434")].joined(separator: "\n")
        XCTAssertEqual(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0\n", runtimeList: list),
                       "iOS 27.0: 24A434")
    }

    /// 実害の形(M1Max): ベータしか無い → 手元の正式版と**違う文字列**になる
    func testBetaOnlyIsMarkedAndDiffersFromTheReleaseFingerprint() {
        let list = [header, line("18.5", "22F77"), line("27.0", "24A5423a")].joined(separator: "\n")
        let beta = SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0", runtimeList: list)
        XCTAssertEqual(beta, "iOS 27.0: 24A5423a (beta)")
        XCTAssertNotEqual(beta, "iOS 27.0: 24A434")
    }

    /// M1Ultra の形: ベータ4つと正式版が同居 → 正式版だけ(起動中の全台が 24A434 だった)。
    /// 並び順は出力の順に依らない
    func testReleaseWinsOverCoexistingBetas() {
        let list = [header, line("27.0", "24A5355p"), line("27.0", "24A5390f"), line("27.0", "24A434"),
                    line("27.0", "24A5408d"), line("27.0", "24A5423a")].joined(separator: "\n")
        XCTAssertEqual(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0", runtimeList: list),
                       "iOS 27.0: 24A434")
    }

    /// SDK と同じ版が1つも無い(= その Xcode ではどの台も起動できない)
    func testNoRuntimeForTheSDKVersion() {
        let list = [header, line("26.2", "23C54")].joined(separator: "\n")
        XCTAssertEqual(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0", runtimeList: list),
                       "iOS 27.0: none")
    }

    /// 使えないと申告された行は数えない
    func testUnavailableRuntimeIsNotCounted() {
        let list = [header, line("27.0", "24A434", suffix: " (unavailable, runtime path not found)"),
                    line("27.0", "24A5423a")].joined(separator: "\n")
        XCTAssertEqual(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0", runtimeList: list),
                       "iOS 27.0: 24A5423a (beta)")
    }

    /// SDK の版が読めない(Xcode が無い機械)は nil = 不明(「違う」に倒さない)
    func testUnknownSDKVersionIsNil() {
        XCTAssertNil(SimulatorRuntimeFingerprint.compose(sdkVersion: " \n",
                                                         runtimeList: [header, line("27.0", "24A434")].joined(separator: "\n")))
    }

    /// 版は**括弧の外のラベル**で SDK と照合する。括弧の中はポイントリリースの版で、SDK の版
    /// (major.minor)と一致しない。実物の行(2026-09-10 この Mac の `simctl list runtimes`)
    func testPointReleaseRuntimeMatchesItsSDKByTheOuterLabel() {
        let list = [header,
                    "iOS 18.1 (18.1 - 22B81) - com.apple.CoreSimulator.SimRuntime.iOS-18-1",
                    "iOS 18.3 (18.3.1 - 22D8075) - com.apple.CoreSimulator.SimRuntime.iOS-18-3"].joined(separator: "\n")
        XCTAssertEqual(SimulatorRuntimeFingerprint.compose(sdkVersion: "18.3", runtimeList: list), "iOS 18.3: 22D8075")
    }

    /// simctl が答えなかった(期限切れ・空・エラー文)は nil = 不明。**`none`(= ⚠️)に倒さない** ——
    /// 見出しだけの一覧(本当にランタイムが無い)とは区別する
    func testNoAnswerFromSimctlIsUnknownNotNone() {
        XCTAssertNil(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0", runtimeList: ""))
        XCTAssertNil(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0",
                                                         runtimeList: "An error was encountered processing the command"))
        XCTAssertEqual(SimulatorRuntimeFingerprint.compose(sdkVersion: "27.0", runtimeList: header), "iOS 27.0: none")
    }

    /// ベータの見分け: 末尾が小文字。**4桁でも末尾が数字なら正式版**(iOS 18.0 の 22A3351)
    func testBetaDetection() {
        for build in ["24A5423a", "23A5260l", "22A5346a", "24A5355p"] {
            XCTAssertTrue(SimulatorRuntimeFingerprint.isBeta(build: build), build)
        }
        for build in ["24A434", "22A3351", "23C54", "22F77"] {
            XCTAssertFalse(SimulatorRuntimeFingerprint.isBeta(build: build), build)
        }
    }
}
