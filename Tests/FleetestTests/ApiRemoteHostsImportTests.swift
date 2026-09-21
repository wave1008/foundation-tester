// `fleetest api remote-machines --import` が受け取る JSON の鍵と、マシン名省略時の既定。
//
// **拡張は machine で送る**(vscode-fleetest/src/remoteRunArgs.ts の RemoteHostEntry)。
// 型の効かない境界なので、鍵の集合をここで固定する。

import XCTest
@testable import fleetest
import FTCore

final class ApiRemoteHostsImportTests: XCTestCase {

    private func decode(_ json: String) throws -> [RemoteHostEntry] {
        try ApiRemoteHostsCommand.decodeImport(json)
    }

    func testReadsTheMachineKeyTheExtensionSends() throws {
        let entries = try decode(#"[{"machine":"M1Max","host":"user@m1max.local","dir":""}]"#)
        XCTAssertEqual(entries.map(\.machine), ["M1Max"])
        XCTAssertEqual(entries.map(\.host), ["user@m1max.local"])
        XCTAssertNil(entries[0].dir, "空文字の dir は未設定として扱う")
    }

    /// 旧キー "name" はもう読まない。指定されても未知キーとして無視され、
    /// machine 省略時と同じ既定(host のホスト部)に落ちる
    func testLegacyNameKeyIsIgnoredAndFallsBackToTheHostPart() throws {
        let entries = try decode(#"[{"name":"old","host":"user@legacy"}]"#)
        XCTAssertEqual(entries.map(\.machine), ["legacy"])
    }

    /// **マシン名は省略可**: 無ければ host のホスト部(user@ を落とす)を名前にする
    func testOmittedMachineFallsBackToTheHostPart() throws {
        let entries = try decode(#"[{"host":"user@m1ultra.local"},{"machine":"  ","host":"192.168.1.20"}]"#)
        XCTAssertEqual(entries.map(\.machine), ["m1ultra.local", "192.168.1.20"])
    }

    /// host は宛先そのものなので省略できない(名前と違い代わりが無い)
    func testHostIsStillRequired() {
        XCTAssertThrowsError(try decode(#"[{"machine":"M1Max"}]"#))
    }

    /// **`fmConcurrency` は import で消えない**。この API のワイヤは machine/host/dir だけなので
    /// (拡張の設定タブがそれしか持たない)、素通しすると設定タブを触っただけで機械ごとの
    /// FM 枠が黙って消える。**取り違えると気づけない型**なので等号で固定する
    func testImportKeepsExistingFMConcurrency() throws {
        let existing = [RemoteHostEntry(machine: "M1Ultra", host: "user@h", fmConcurrency: 1)]
        let incoming = try ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","dir":""}]"#)
        let raw = try XCTUnwrap(incoming.first)
        XCTAssertNil(raw.fmConcurrency, "キーを送っていない")
        // キーを送っていない = 既存値を保つ(設定タブ以外のクライアントが upsert しても消えない)
        let merged = ApiRemoteHostsCommand.mergingFMConcurrency(raw.entry, sentKey: false, from: existing)
        XCTAssertEqual(merged.fmConcurrency, 1)

        // 未登録の機械には持ち越すものが無い
        XCTAssertNil(ApiRemoteHostsCommand.mergingFMConcurrency(raw.entry, sentKey: false, from: [])
                        .fmConcurrency)
    }

    /// **設定タブは常にキーを送る**ので、その指定が既存値より優先される。
    /// 空欄は 0 で届き「解除」になる —— ここが効かないと GUI から外せない
    func testImportHonoursExplicitFMConcurrency() throws {
        let existing = [RemoteHostEntry(machine: "M1Ultra", host: "user@h", fmConcurrency: 1)]

        let set = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","dir":"","fmConcurrency":3}]"#).first)
        XCTAssertEqual(set.fmConcurrency, 3, "キーを送ったことが分かる")
        XCTAssertEqual(ApiRemoteHostsCommand.mergingFMConcurrency(
            set.entry, sentKey: set.fmConcurrency != nil, from: existing).fmConcurrency, 3)

        let cleared = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","dir":"","fmConcurrency":0}]"#).first)
        XCTAssertEqual(cleared.fmConcurrency, 0, "0 もキーとして届く(nil ではない)")
        XCTAssertNil(ApiRemoteHostsCommand.mergingFMConcurrency(
            cleared.entry, sentKey: cleared.fmConcurrency != nil, from: existing).fmConcurrency,
                     "空欄(0)は解除")
    }

    // MARK: - color

    func testDecodeReadsColorKey() throws {
        let entries = try ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Max","host":"user@h","color":"mint"}]"#)
        XCTAssertEqual(entries.first?.entry.color, "mint")
    }

    /// "" と欠落は未設定(upsert が保つ/割り当てる)
    func testEmptyOrMissingColorIsNil() throws {
        let entries = try ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"a","host":"h1","color":""},{"machine":"b","host":"h2"}]"#)
        XCTAssertNil(entries[0].entry.color)
        XCTAssertNil(entries[1].entry.color)
    }

    func testValidateColorAcceptsKnownKey() {
        XCTAssertNoThrow(try ApiRemoteHostsCommand.validateColor("rose"))
    }

    func testValidateColorAcceptsNilAndEmpty() {
        XCTAssertNoThrow(try ApiRemoteHostsCommand.validateColor(nil))
        XCTAssertNoThrow(try ApiRemoteHostsCommand.validateColor(""))
    }

    /// 非空の未知色は --import 全体を拒否する
    func testValidateColorRejectsUnknownKey() {
        XCTAssertThrowsError(try ApiRemoteHostsCommand.validateColor("chartreuse"))
    }

    /// mergingFMConcurrency が color を作り直しで落とさない
    func testMergingFMConcurrencyKeepsColor() throws {
        let incoming = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","color":"mint"}]"#).first)
        let merged = ApiRemoteHostsCommand.mergingFMConcurrency(
            incoming.entry, sentKey: false, from: [])
        XCTAssertEqual(merged.color, "mint")
    }

    /// 「マシン有効」: キーを送れば import が運び、mergingFMConcurrency が作り直しで落とさない
    func testImportCarriesEnabledThroughTheFMMerge() throws {
        let incoming = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","enabled":false}]"#).first)
        XCTAssertEqual(ApiRemoteHostsCommand.mergingFMConcurrency(
            incoming.entry, sentKey: false, from: []).enabled, false)
        let absent = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h"}]"#).first)
        XCTAssertNil(absent.entry.enabled)
    }

    // MARK: - developerDir (Xcode pin)

    func testDecodeReadsDeveloperDirKey() throws {
        let entries = try ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Max","host":"user@h","developerDir":"/Applications/Xcode_27.app/Contents/Developer"}]"#)
        XCTAssertEqual(entries.first?.entry.developerDir, "/Applications/Xcode_27.app/Contents/Developer")
    }

    /// "" と欠落は entry レベルでは同じ(nil)だが、**mergingDeveloperDir はキーの有無だけで
    /// 区別する**(--import の往復で pin が消えないこと の核心)。この2つを区別できないと、
    /// developerDir を知らないクライアントが import するたびに他機の pin が消える
    func testImportKeepsExistingDeveloperDirWhenKeyIsAbsent() throws {
        let existing = [RemoteHostEntry(machine: "M1Ultra", host: "user@h",
                                        developerDir: "/Applications/Xcode_27.app/Contents/Developer")]
        // developerDir を知らない旧いクライアントの import(キー自体が無い)
        let incoming = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h"}]"#).first)
        XCTAssertNil(incoming.developerDir, "キーを送っていない")
        let merged = ApiRemoteHostsCommand.mergingDeveloperDir(
            incoming.entry, sentKey: incoming.developerDir != nil, from: existing)
        XCTAssertEqual(merged.developerDir, "/Applications/Xcode_27.app/Contents/Developer",
                       "pin が消えないこと")
    }

    /// 新しいクライアントが明示的に "" を送れば消える(pin を外す唯一の JSON 経路)。
    /// 実値を送れば上書きされる。どちらも sentKey=true として届く(fmConcurrency の 0 と同じ形)
    func testImportHonoursExplicitDeveloperDir() throws {
        let existing = [RemoteHostEntry(machine: "M1Ultra", host: "user@h",
                                        developerDir: "/Applications/Xcode_27.app/Contents/Developer")]

        let cleared = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","developerDir":""}]"#).first)
        XCTAssertEqual(cleared.developerDir, "", "キーとしては届く(nil ではない)")
        XCTAssertNil(ApiRemoteHostsCommand.mergingDeveloperDir(
            cleared.entry, sentKey: cleared.developerDir != nil, from: existing).developerDir)

        let set = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","developerDir":"/Applications/Xcode_26.2.app/Contents/Developer"}]"#)
            .first)
        XCTAssertEqual(ApiRemoteHostsCommand.mergingDeveloperDir(
            set.entry, sentKey: set.developerDir != nil, from: existing).developerDir,
            "/Applications/Xcode_26.2.app/Contents/Developer")
    }

    /// mergingFMConcurrency は developerDir を作り直しで落とさない(2つの merge を続けて
    /// 適用する ApiRemoteHostsCommand.run() の実際の順序と同じ前提)
    func testMergingFMConcurrencyKeepsDeveloperDir() throws {
        let incoming = try XCTUnwrap(ApiRemoteHostsCommand.decodeImportEntries(
            #"[{"machine":"M1Ultra","host":"user@h","developerDir":"/Applications/Xcode_27.app/Contents/Developer"}]"#)
            .first)
        let merged = ApiRemoteHostsCommand.mergingFMConcurrency(
            incoming.entry, sentKey: false, from: [])
        XCTAssertEqual(merged.developerDir, "/Applications/Xcode_27.app/Contents/Developer")
    }
}
