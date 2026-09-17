// `fleetest bridge up` は稼働中ブリッジを再利用する場合でも xcodegen/build-for-testing を
// 無条件に撃っていた(実測 2026-09-18 N2: 稼働中ポートの再利用だけの呼び出しでも
// build-for-testing が走った)。ビルドの要否判定は provision()
// (BridgeProvisioner.prepareSharedBuilds。xctestrun 不在・ランナーソース変更の両方をカバーする)
// に一本化し、CLI 側の無条件呼び出しは削除した。**この形が戻らないことをソース走査で固定する。**
// `--skip-build` は provision() 委譲後は意味を持たないため削除済み(未公開ツールなので別名は置かない)。

import XCTest

final class BridgeUpNoDuplicateBuildTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let path = "Sources/fleetest/Fleetest.swift"

    /// `struct Up`(次の `struct Down` の直前まで)だけを切り出す。`run`/`api run` にも同名
    /// `--skip-build`(swift build 自体の省略。無関係の別物)があるため、走査を `Bridge.Up` の
    /// 宣言範囲に絞らないと無関係のフラグを誤検出する
    private static func upStructSource() throws -> String {
        let fileURL = repoRoot.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "走査対象が実在しない: \(fileURL.path)")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "struct Up: AsyncParsableCommand {"),
                                  "Bridge.Up の宣言が見つからない(走査の前提が崩れた)")
        let end = try XCTUnwrap(text.range(of: "struct Down: AsyncParsableCommand {"),
                                "Bridge.Down の宣言が見つからない(走査の前提が崩れた)")
        XCTAssertLessThan(start.lowerBound, end.lowerBound)
        let source = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(source.contains("func run() async throws {"),
                      "切り出した範囲に run() が無い(走査が空振りしている)")
        return source
    }

    /// provision() の鮮度判定と二重にビルドを撃つ無条件呼び出しが戻っていないこと
    func testRunNeverCallsBuildForTestingUnconditionally() throws {
        let source = try Self.upStructSource()
        XCTAssertFalse(source.contains("buildForTesting()"),
                       "Bridge.Up が build-for-testing を再び直接撃っている"
                        + " —— provision()(BridgeProvisioner.prepareSharedBuilds)の鮮度判定と二重化する")
    }

    /// 意味を失った `--skip-build`(bridge up 専用)が復活していないこと
    func testSkipBuildFlagWasRemoved() throws {
        let source = try Self.upStructSource()
        XCTAssertFalse(source.contains("skipBuild"),
                       "bridge up の --skip-build が復活している"
                        + "(provision() 委譲後はビルドの要否を CLI 側で選べない)")
    }

    /// xcodegen(generateProjectIfNeeded)は SampleApp のビルド(installSampleApp が使う
    /// Xcode project)専用に残す。provision() が xcuitest ランナー用のプロジェクト生成を担うため、
    /// withSampleApp の外で無条件に撃つ形へ戻さない
    func testGenerateProjectIfNeededOnlyRunsForSampleApp() throws {
        let source = try Self.upStructSource()
        let withSampleAppRange = try XCTUnwrap(source.range(of: "if withSampleApp {"),
                                               "withSampleApp 分岐が見つからない(走査の前提が崩れた)")
        let before = source[source.startIndex..<withSampleAppRange.lowerBound]
        XCTAssertFalse(before.contains("generateProjectIfNeeded()"),
                       "withSampleApp より前で xcodegen を無条件に撃っている")
        XCTAssertTrue(source[withSampleAppRange.lowerBound...].contains("generateProjectIfNeeded()"),
                      "installSampleApp 用の generateProjectIfNeeded が消えている")
    }

    /// 委譲先(provision())自体が消えていないこと(空振り防止 = 上のテストが常に真になる退化を防ぐ)
    func testRunStillDelegatesToProvisioner() throws {
        let source = try Self.upStructSource()
        XCTAssertTrue(source.contains("BridgeProvisioner(repoRoot: root)")
                      && source.contains(".provision(devices:"),
                      "provision() への委譲が消えている")
    }
}
