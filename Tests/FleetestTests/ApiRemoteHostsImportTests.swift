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
}
