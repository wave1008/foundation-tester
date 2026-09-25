// `fleetest remote status` の TOOLCHAIN 列 / `api remote-compat` の toolchainCompatible・
// toolchainAdvisory の検証。
//
// 製品版(Xcode 27.0 等)が同じで build 番号だけ違う(ベータ seed 違い)は advisory(⚠️・
// ディスパッチは止めない)、それ以外の toolchain 差(製品版違い・片方 nil)は従来どおり
// blocking(❌・ディスパッチを止める)。判定そのものは FTRemote.RemoteCompat.verdict(別途
// Tests/FTCoreTests/RemoteDispatchTests+HostCompat.swift で検証)なので、ここは HostReport 経由の
// 配線(toolchainCell・toolchainCompatible・toolchainAdvisory)だけを見る。

import FTCore
import FTRemote
import XCTest
@testable import fleetest

final class RemoteStatusToolchainCellTests: XCTestCase {

    private func report(localToolchain: String?, remoteToolchain: String?,
                        revision: String = "abc") -> HostReport {
        let status = RemoteHostStatus(session: nil, revision: revision, toolchain: remoteToolchain,
                                      binaryPresent: true, freeKB: nil)
        let row = HostRow(sshTarget: "host", reachable: true, detail: nil, status: status, fmOK: nil)
        return HostReport(row: row, localRevision: revision, localToolchain: localToolchain)
    }

    func testMatchingToolchainIsGreen() {
        let r = report(localToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1",
                       remoteToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(r.toolchainCompatible, true)
        XCTAssertNil(r.toolchainAdvisory)
        XCTAssertEqual(RemoteCommand.Status.toolchainCell(r, value: r.status?.toolchain),
                       "✅ Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
    }

    /// 製品版が同じで build だけ違う(ベータ seed) → advisory(⚠️)。ディスパッチは止まらない
    func testBetaSeedOnlyDifferenceIsAdvisoryYellow() {
        let r = report(localToolchain: "Xcode 27.0 Build version 27A5228h / iphonesimulator 24A434",
                       remoteToolchain: "Xcode 27.0 Build version 27A5231e / iphonesimulator 24A5423a")
        XCTAssertEqual(r.toolchainCompatible, true, "advisory は互換扱い(止めない)")
        XCTAssertNotNil(r.toolchainAdvisory)
        XCTAssertTrue(r.toolchainAdvisory!.contains("beta seed"), r.toolchainAdvisory!)
        XCTAssertEqual(RemoteCommand.Status.toolchainCell(r, value: r.status?.toolchain),
                       "⚠️ Xcode 27.0 Build version 27A5231e / iphonesimulator 24A5423a")
    }

    /// 製品版そのものが違う(26 vs 27) → 従来どおり blocking(❌)
    func testDifferentProductVersionIsBlockingRed() {
        let r = report(localToolchain: "Xcode 26.3 Build version 26C1 / iphonesimulator 26C1",
                       remoteToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(r.toolchainCompatible, false)
        XCTAssertNil(r.toolchainAdvisory, "blocking のときは advisory を立てない")
        XCTAssertEqual(RemoteCommand.Status.toolchainCell(r, value: r.status?.toolchain),
                       "❌ Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
    }

    /// fail-closed: 片方が読めない(nil)なら blocking のまま(advisory へ倒さない)
    func testUnreadableRemoteToolchainIsBlockingRed() {
        let r = report(localToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1",
                       remoteToolchain: nil)
        XCTAssertEqual(r.toolchainCompatible, false)
        XCTAssertNil(r.toolchainAdvisory)
        XCTAssertEqual(RemoteCommand.Status.toolchainCell(r, value: r.status?.toolchain), "❌ ?")
    }

    /// rev 側は blocking のまま(仕様どおり)。REV 欄の表記自体は 2 値のまま変えない
    /// (RemoteCommands.swift の `mark` を経由。ここでは verdict の配線だけ確かめる)
    func testRevisionMismatchStaysBlockingRegardlessOfToolchain() {
        let status = RemoteHostStatus(session: nil, revision: "def",
                                      toolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1",
                                      binaryPresent: true, freeKB: nil)
        let row = HostRow(sshTarget: "host", reachable: true, detail: nil, status: status, fmOK: nil)
        let r = HostReport(row: row, localRevision: "abc",
                           localToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(r.revisionCompatible, false)
        XCTAssertFalse(r.compatible, "revision の blocking だけでも compatible は false")
    }

    /// unreachable(status なし)は判定不能 → nil(compatible 判定にだけ効かせ、blocking/advisory
    /// どちらへも倒さない)
    func testUnreachableHostHasNoVerdictOpinion() {
        let row = HostRow(sshTarget: "host", reachable: false, detail: "unreachable", status: nil, fmOK: nil)
        let r = HostReport(row: row, localRevision: "abc", localToolchain: "Xcode 27.0")
        XCTAssertNil(r.toolchainCompatible)
        XCTAssertNil(r.revisionCompatible)
        XCTAssertFalse(r.compatible)
    }

    // MARK: - Xcode 選択の拒否(docs/remote-runner.md §7)

    /// XcodeSelection が refused(候補が複数/0個)のときは、**toolchain の文字列が一致していても**
    /// TOOLCHAIN が ❌ になる ―― これが無いと「ambient がたまたま一致した」ときだけ緑になる
    /// 運任せの判定になる(候補一覧を出して拒否したのに表は緑、という食い違いを防ぐ)
    func testXcodeSelectionRefusalForcesToolchainRedEvenIfStringsMatch() {
        let status = RemoteHostStatus(
            session: nil, revision: "abc",
            toolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1",
            binaryPresent: true, freeKB: nil)
        let row = HostRow(sshTarget: "host", reachable: true, detail: nil, status: status, fmOK: nil,
                          xcodeSelectionRefusalReason: "could not tell which installed Xcode to dispatch with"
                              + " (candidates: Xcode 27.0 (build 27A1) at /Applications/Xcode_27.app,"
                              + " Xcode 27.0 (build 27A2) at /Applications/Xcode_27_beta.app)")
        let r = HostReport(row: row, localRevision: "abc",
                           localToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(r.toolchainCompatible, false)
        XCTAssertFalse(r.compatible)
        XCTAssertEqual(RemoteCommand.Status.toolchainCell(r, value: r.status?.toolchain),
                       "❌ Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(r.xcodeSelectionRefusalReason, row.xcodeSelectionRefusalReason)
    }

    /// nil(pin 済み・自動選択できた・候補ゼロで ambient)なら、従来どおり文字列比較だけで決まる
    func testNoXcodeSelectionRefusalLeavesToolchainVerdictUnaffected() {
        let status = RemoteHostStatus(
            session: nil, revision: "abc",
            toolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1",
            binaryPresent: true, freeKB: nil)
        let row = HostRow(sshTarget: "host", reachable: true, detail: nil, status: status, fmOK: nil)
        XCTAssertNil(row.xcodeSelectionRefusalReason)
        let r = HostReport(row: row, localRevision: "abc",
                           localToolchain: "Xcode 27.0 Build version 27A1 / iphonesimulator 27A1")
        XCTAssertEqual(r.toolchainCompatible, true)
        XCTAssertNil(r.xcodeSelectionRefusalReason)
    }
}
