// `fleetest api remote-hosts --import` が受け取る JSON の鍵と、マシン名省略時の既定。
//
// **拡張は machine で送る**(vscode-fleetest/src/remoteRunArgs.ts の RemoteHostEntry)。
// 2026-08-27 まで実装は旧キー name だけを必須で読んでおり、**設定タブからのマシン登録が
// 常に「--import is not a valid JSON array」で失敗していた**(2026-08-26 の改名で
// 片側だけ残った)。型の効かない境界なので、鍵の集合をここで固定する。

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

    func testStillReadsTheLegacyNameKey() throws {
        let entries = try decode(#"[{"name":"old","host":"user@legacy"}]"#)
        XCTAssertEqual(entries.map(\.machine), ["old"])
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
}
