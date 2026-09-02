// `fleetest remote status` の FM 列の検証。
//
// この列の目的は**「どのランナーで FM が使えるか」を機械ごとに ssh して実呼び出しせずに
// 済ませる**こと(今日それを手で2回やった)。供給はランナーの死活台帳で、status が既に張って
// いる ssh 1本で読む —— **FM 呼び出しはゼロ**。だから、誤った断定をしない側へ倒す規律が要る。

import FTCore
import FTRemote
import XCTest
@testable import fleetest

final class RemoteStatusFMCellTests: XCTestCase {
    private let now = Date()

    private func verdict(_ state: FMLiveness.State, ageSeconds: TimeInterval = 0) -> FMLiveness.Verdict {
        FMLiveness.Verdict(state: state,
                           checkedAt: now.addingTimeInterval(-ageSeconds).timeIntervalSince1970,
                           source: .probe, error: state == .dead ? "boom" : nil)
    }

    private func cell(live: Bool? = nil, _ record: FMLiveness.Record?) -> String {
        RemoteCommand.Status.fmCell(live: live, ledger: record, now: now)
    }

    /// 死んだ経路を名指しする —— text と vision で無効になる機能が違うので、"ng" だけでは
    /// そのランナーへ何を投げてよいかが決まらない
    func testDeadPathsAreNamed() {
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.alive), vision: verdict(.dead))),
                       "ng:vision")
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.dead), vision: verdict(.dead))),
                       "ng:text+vision")
    }

    /// **両方 生 と確かめられたときだけ ok**。片方が不明のまま ok と言うと、観測できていない
    /// 経路が死んでいる可能性を隠す(不明と生を混ぜない)
    func testOKOnlyWhenBothPathsAreConfirmedAlive() {
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.alive), vision: verdict(.alive))), "ok")
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.alive), vision: nil)), "-",
                       "vision を観測できていないなら ok とは言わない")
        XCTAssertEqual(cell(FMLiveness.Record(text: nil, vision: verdict(.alive))), "-")
    }

    /// 台帳が無い(旧ランナー・一度も観測していない)は不明。**「生きている」に倒さない**
    func testMissingLedgerIsUnknown() {
        XCTAssertEqual(cell(nil), "-")
        XCTAssertEqual(cell(FMLiveness.Record()), "-")
    }

    /// 古い記録は不明へ倒す。**向こうの時計がずれていても、生死を誤って断定する方向へは
    /// 倒れない**(ずれた機械では新しい記録も古く見え、"-" になるだけ)
    func testStaleRecordsFallBackToUnknown() {
        let stale = FMLiveness.freshSeconds + 1
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.dead, ageSeconds: stale),
                                              vision: verdict(.dead, ageSeconds: stale))), "-")
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.alive, ageSeconds: stale),
                                              vision: verdict(.alive, ageSeconds: stale))), "-")
        XCTAssertEqual(cell(FMLiveness.Record(text: verdict(.alive),
                                              vision: verdict(.dead, ageSeconds: stale))), "-",
                       "古い死は死と言わない(直っているかもしれない)")
    }

    /// `--fm`(実呼び出し)を付けた回はそちらが勝つ —— 台帳より新しく、根拠も強い
    func testLiveProbeWinsOverTheLedger() {
        let deadLedger = FMLiveness.Record(text: verdict(.dead), vision: verdict(.dead))
        XCTAssertEqual(cell(live: true, deadLedger), "ok")
        XCTAssertEqual(cell(live: false, FMLiveness.Record(text: verdict(.alive), vision: verdict(.alive))),
                       "ng")
    }
}

/// 台帳を運ぶ ssh ブロックの検証。**status は FM を叩かない** —— 叩くとホスト数ぶん
/// 直列化の枠を奪い、しかも測る対象を自分で消費する
final class RemoteStatusFMProbeTests: XCTestCase {

    private var layout: RemoteLayout {
        RemoteLayout(base: "$HOME/fleetest-runner", issuer: "u")
    }

    /// 読むのは**レイアウトの外**の ~/.fleetest(FM はホストの資源で、プロジェクトにも
    /// 発行者にも属さない)。**実呼び出しのコマンドを混ぜない**
    func testCommandReadsTheLedgerWithoutCallingFM() {
        let command = RemoteStatusProbe.command(layout: layout)
        XCTAssertTrue(command.contains("$HOME/.fleetest/fm-liveness.json"), command)
        XCTAssertFalse(command.contains("doctor"), "status から FM を実呼び出ししない。\(command)")
        XCTAssertFalse(command.contains("--fm-only"), command)
    }

    func testParsesTheLedgerBlock() throws {
        let json = #"{"text":{"state":"alive","checkedAt":1,"source":"probe"},"#
            + #""vision":{"state":"dead","checkedAt":2,"source":"call","error":"boom"}}"#
        let record = try XCTUnwrap(RemoteStatusProbe.parseFMLiveness(json))
        XCTAssertEqual(record.text?.state, .alive)
        XCTAssertEqual(record.vision?.state, .dead)
        XCTAssertEqual(record.vision?.error, "boom")
    }

    /// 台帳が無い(cat が空)・壊れているは nil = 不明。**空を「生きている」と読まない**
    func testEmptyOrBrokenLedgerIsUnknown() {
        XCTAssertNil(RemoteStatusProbe.parseFMLiveness(""))
        XCTAssertNil(RemoteStatusProbe.parseFMLiveness("   \n  "))
        XCTAssertNil(RemoteStatusProbe.parseFMLiveness("cat: no such file"))
    }

    /// 片方の経路しか記録が無い状態は正常(独立に死ぬので独立に書かれる)—— 読める枝は活かす
    func testPartialLedgerKeepsTheKnownPath() throws {
        let record = try XCTUnwrap(RemoteStatusProbe.parseFMLiveness(
            #"{"vision":{"state":"dead","checkedAt":2,"source":"probe"}}"#))
        XCTAssertNil(record.text)
        XCTAssertEqual(record.vision?.state, .dead)
    }

    /// 旧ランナー(ブロックが7個しか無い出力)でも他の項目は読めて、FM だけ不明になる
    func testOldRunnerOutputStillParsesEverythingElse() {
        let sep = "\n---FT---\n"
        let output = ["/Users/u\nu\nu", "abc123", "Xcode 27.0\nBuild version 27A1", "24A1",
                      "yes", "/dev/disk1 1 2 3000 1% /", "absent"].joined(separator: sep)
        let status = RemoteStatusProbe.parse(output)
        XCTAssertEqual(status.revision, "abc123")
        XCTAssertNil(status.fmLiveness, "欄が無い = 不明(生きているに倒さない)")
    }
}
