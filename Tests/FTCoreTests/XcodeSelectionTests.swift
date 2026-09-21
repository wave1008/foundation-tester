// ランナー機に複数の Xcode が入っているときの自動選択(docs/remote-runner.md §7)。
// ssh/プロセス起動は Sources/fleetest/RemoteRunDispatcher.swift・RemoteCommands.swift 側
// (ここは列挙の解析・選択規則だけの純粋ロジック)。

import Foundation
import XCTest
import FTCore
import FTRemote

final class XcodeSelectionTests: XCTestCase {

    // MARK: - parse

    /// 実機で採った本物の1行の形(タスク添付の実測値)
    func testParseRealLine() {
        let installed = XcodeSelection.parse("27.0|27A266a|/Applications/Xcode_27.app")
        XCTAssertEqual(installed, [
            XcodeSelection.Installed(productVersion: "27.0", build: "27A266a", path: "/Applications/Xcode_27.app"),
        ])
    }

    func testParseMultipleLines() {
        let output = """
            27.0|27A266a|/Applications/Xcode_27.app
            26.2|26C143|/Applications/Xcode_26.2.app
            """
        let installed = XcodeSelection.parse(output)
        XCTAssertEqual(installed.map(\.productVersion), ["27.0", "26.2"])
        XCTAssertEqual(installed.map(\.build), ["27A266a", "26C143"])
    }

    /// 区切りが足りない・いずれかが空の行は落とす(1本読めれば十分。全滅は呼び出し側が ambient に倒す)
    func testParseDropsMalformedLines() {
        let output = """
            27.0|27A266a|/Applications/Xcode_27.app
            not-a-valid-line
            |27B1|/Applications/Xcode_broken.app
            26.2||/Applications/Xcode_no_build.app
            """
        let installed = XcodeSelection.parse(output)
        XCTAssertEqual(installed, [
            XcodeSelection.Installed(productVersion: "27.0", build: "27A266a", path: "/Applications/Xcode_27.app"),
        ])
    }

    func testParseEmptyOutputYieldsEmptyArray() {
        XCTAssertEqual(XcodeSelection.parse(""), [])
        XCTAssertEqual(XcodeSelection.parse("\n\n"), [])
    }

    func testInstalledDeveloperDirIsDerivedFromPath() {
        let installed = XcodeSelection.Installed(
            productVersion: "27.0", build: "27A266a", path: "/Applications/Xcode_27.app")
        XCTAssertEqual(installed.developerDir, "/Applications/Xcode_27.app/Contents/Developer")
    }

    // MARK: - resolve

    private let xcode27 = XcodeSelection.Installed(
        productVersion: "27.0", build: "27A266a", path: "/Applications/Xcode_27.app")
    private let xcode27Beta = XcodeSelection.Installed(
        productVersion: "27.0", build: "27A5228h", path: "/Applications/Xcode_27_beta.app")
    private let xcode26 = XcodeSelection.Installed(
        productVersion: "26.2", build: "26C143", path: "/Applications/Xcode_26.2.app")

    /// pin があれば列挙・指紋を見るまでもなく勝つ。**存在確認はしない**。
    /// pin は利用者向けの案内どおり `.app` バンドルのパスで渡す(docs/remote-runner-setup.md の例:
    /// `--developer-dir /Applications/Xcode_27.app`)—— 実際に export する `DEVELOPER_DIR` は
    /// そこから "/Contents/Developer" を補ったもの(自動選択の `Installed.developerDir` と同じ形)
    func testPinAcceptsTheAppBundlePathAndAppendsContentsDeveloper() {
        let outcome = XcodeSelection.resolve(
            localFingerprint: nil, installed: [], pin: "/Applications/Xcode_pinned.app")
        XCTAssertEqual(outcome, .pinned("/Applications/Xcode_pinned.app/Contents/Developer"))
        XCTAssertEqual(outcome.developerDir, "/Applications/Xcode_pinned.app/Contents/Developer")
    }

    /// 末尾スラッシュ付きの `.app` パスでも二重に補わない
    func testPinStripsTrailingSlashBeforeAppending() {
        let outcome = XcodeSelection.resolve(
            localFingerprint: nil, installed: [], pin: "/Applications/Xcode_pinned.app/")
        XCTAssertEqual(outcome, .pinned("/Applications/Xcode_pinned.app/Contents/Developer"))
    }

    /// 既に DEVELOPER_DIR そのもの("/Contents/Developer" で終わる)を渡した場合はそのまま使う
    /// (二重に補わない。手書き設定の保険)
    func testPinAlreadyEndingInContentsDeveloperIsUsedAsIs() {
        let outcome = XcodeSelection.resolve(
            localFingerprint: nil, installed: [], pin: "/Applications/Xcode_pinned.app/Contents/Developer")
        XCTAssertEqual(outcome, .pinned("/Applications/Xcode_pinned.app/Contents/Developer"))
    }

    /// 空白だけの pin は「pin なし」として扱う(手書き設定の "" を誤って有効な pin にしない)
    func testBlankPinIsTreatedAsNoPin() {
        let outcome = XcodeSelection.resolve(
            localFingerprint: nil, installed: [], pin: "   ")
        XCTAssertEqual(outcome, .ambient)
    }

    /// build 番号までちょうど1つ一致すれば、その候補を選ぶ(製品版だけの一致より優先)
    func testResolveSelectsUniqueBuildMatch() {
        let local = "Xcode 27.0 Build version 27A266a / iphonesimulator 24A434"
        let outcome = XcodeSelection.resolve(
            localFingerprint: local, installed: [xcode27, xcode27Beta, xcode26], pin: nil)
        XCTAssertEqual(outcome, .selected(xcode27))
        XCTAssertEqual(outcome.developerDir, xcode27.developerDir)
    }

    /// build が一致しなければ製品版(Xcode X.Y)でちょうど1つに絞る
    func testResolveFallsBackToUniqueProductVersionMatch() {
        let local = "Xcode 26.2 Build version 26ZZZZ / iphonesimulator 24A434"
        let outcome = XcodeSelection.resolve(
            localFingerprint: local, installed: [xcode27, xcode27Beta, xcode26], pin: nil)
        XCTAssertEqual(outcome, .selected(xcode26))
    }

    /// 製品版も複数(ベータ seed 違いの2本)ある場合は build 一致が無ければ refuse
    /// (どちらのベータかを機械が勝手に決めない)
    func testResolveRefusesWhenProductVersionMatchesMultipleCandidates() {
        let local = "Xcode 27.0 Build version 27ZZZZZ / iphonesimulator 24A434"
        let outcome = XcodeSelection.resolve(
            localFingerprint: local, installed: [xcode27, xcode27Beta], pin: nil)
        guard case .refused(let reason) = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("27A266a"), reason)
        XCTAssertTrue(reason.contains("27A5228h"), reason)
        XCTAssertTrue(reason.contains("/Applications/Xcode_27.app"), reason)
        XCTAssertTrue(reason.contains("/Applications/Xcode_27_beta.app"), reason)
        // **対処は pin**。ここで「どれも一致しない」と言うと利用者は Xcode を入れ直しに行く
        XCTAssertTrue(reason.contains("pin one for this machine"), reason)
        XCTAssertFalse(reason.contains("none of the"), reason)
        XCTAssertNil(outcome.developerDir)
    }

    /// 一致0個(手元と縁もゆかりもない版だけが入っている)も refuse。候補一覧を必ず載せる
    func testResolveRefusesWhenNoCandidateMatches() {
        let local = "Xcode 99.0 Build version 99ZZZZZ / iphonesimulator 24A434"
        let outcome = XcodeSelection.resolve(localFingerprint: local, installed: [xcode26], pin: nil)
        guard case .refused(let reason) = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("26.2"), reason)
        XCTAssertTrue(reason.contains("26C143"), reason)
        // **対処は「その Xcode を入れる」**。pin を勧めると、pin しても指紋照合で止まるので堂々巡りになる
        XCTAssertTrue(reason.contains("install the matching Xcode"), reason)
        XCTAssertFalse(reason.contains("pin one for this machine"), reason)
    }

    /// 候補ゼロ(列挙できなかった・Xcode が1本も無い)は ambient —— 運用を止めない
    func testResolveIsAmbientWhenNoCandidatesAtAll() {
        XCTAssertEqual(XcodeSelection.resolve(localFingerprint: nil, installed: [], pin: nil), .ambient)
        XCTAssertEqual(
            XcodeSelection.resolve(
                localFingerprint: "Xcode 27.0 Build version 27A266a", installed: [], pin: nil),
            .ambient)
        XCTAssertNil(XcodeSelection.Outcome.ambient.developerDir)
    }

    /// 手元の指紋が取れない(localFingerprint == nil)場合も、候補が1本だけなら選べない
    /// (一致を判定する材料が無いので refuse。誤って唯一の候補へ倒さない)
    func testResolveRefusesWhenLocalFingerprintIsNilEvenWithOneCandidate() {
        let outcome = XcodeSelection.resolve(localFingerprint: nil, installed: [xcode27], pin: nil)
        guard case .refused = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
    }
}
