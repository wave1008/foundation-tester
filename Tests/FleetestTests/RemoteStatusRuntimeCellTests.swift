// `fleetest remote status` の RUNTIME 列の検証。
//
// **警告だけの欄**(新しい検知はまず警告から)なので、守るのは誤って鳴らさない側 ——
// どちらかが読めない(Xcode の無い機械・旧形の出力)ときは「違う」ではなく不明にする。
// もう1つは配線: ランタイムを採るのは `remote status` だけ(ソース走査で固定)。

import XCTest
@testable import fleetest

final class RemoteStatusRuntimeCellTests: XCTestCase {

    /// 実害の形(2026-09-10 M1Max): 手元は正式版・向こうはベータだけ → ⚠️
    func testBetaOnlyRunnerIsFlagged() {
        XCTAssertEqual(RemoteCommand.Status.runtimeMatches(local: "iOS 27.0: 24A434",
                                                           remote: "iOS 27.0: 24A5423a (beta)"), false)
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434",
                                                        remote: "iOS 27.0: 24A5423a (beta)"),
                       "⚠️ iOS 27.0: 24A5423a (beta)")
    }

    func testMatchingRunnerIsGreen() {
        XCTAssertEqual(RemoteCommand.Status.runtimeMatches(local: "iOS 27.0: 24A434", remote: "iOS 27.0: 24A434"), true)
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434", remote: "iOS 27.0: 24A434"),
                       "✅ iOS 27.0: 24A434")
    }

    /// **`none`(その SDK のランタイムが1本も無い)は一致していても ⚠️** —— 全機が等しく「無い」ときに
    /// ✅ を出すと、その iOS の台を要求した run が供給で落ちるまで誰も気づかない。
    /// 自動選択が入って到達しやすくなった状態(2026-09-21 に Xcode 27.2 beta の実機で観測)
    func testNoMatchingRuntimeWarnsEvenWhenBothSidesAgree() {
        XCTAssertEqual(RemoteCommand.Status.runtimeMatches(local: "iOS 27.2: none",
                                                           remote: "iOS 27.2: none"), true,
                       "一致の判定そのものは変えない(手元と同じかを答える別の問い)")
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.2: none", remote: "iOS 27.2: none"),
                       "⚠️ iOS 27.2: none")
        // 手元が不明でも鳴る(手元の simctl が期限切れでも、向こうに無い事実は変わらない)
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: nil, remote: "iOS 27.2: none"),
                       "⚠️ iOS 27.2: none")
        // 持っている側は従来どおり緑(誤検知を増やさない)
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434", remote: "iOS 27.0: 24A434"),
                       "✅ iOS 27.0: 24A434")
    }

    /// 不明は「違う」に倒さない(倒すと Xcode の無い機械で毎回鳴る)
    func testUnknownOnEitherSideIsNotAMismatch() {
        XCTAssertNil(RemoteCommand.Status.runtimeMatches(local: nil, remote: "iOS 27.0: 24A434"))
        XCTAssertNil(RemoteCommand.Status.runtimeMatches(local: "iOS 27.0: 24A434", remote: nil))
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: nil, remote: "iOS 27.0: 24A434"), "iOS 27.0: 24A434")
        XCTAssertEqual(RemoteCommand.Status.runtimeCell(local: "iOS 27.0: 24A434", remote: nil), "-")
    }

    /// **ランタイムを採るのは `remote status` だけ**。`api remote-compat` は拡張がリモート実行の前に
    /// 毎回待つ経路で値を読まないので、simctl の往復(0.4〜1 秒・サービスが刺されば期限まで)を
    /// 払わせない。`wantRuntime` に既定値は無いので書き忘れはコンパイルで止まるが、**逆の値を書いても
    /// 型は通る** —— ここで呼び出し元の集合と値を等号で固定する(新しい呼び出し元も落ちて目に入る)
    func testOnlyRemoteStatusProbesTheRuntime() throws {
        var calls: [String: [String]] = [:]
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "Sources に届いていない(走査の前提が崩れた)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated()
            where line.contains("RemoteStatusProbing.probe(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let call = lines[index..<min(index + 3, lines.count)].joined(separator: " ")
                let value = call.range(of: #"wantRuntime: \w+"#, options: .regularExpression).map { String(call[$0]) }
                let relative = String(file.path.dropFirst(Self.repoRoot.path.count + 1))
                calls[relative, default: []].append(value ?? "(wantRuntime が見つからない)")
            }
        }
        XCTAssertEqual(calls, [
            "Sources/fleetest/RemoteCommands.swift": ["wantRuntime: true"],
            "Sources/fleetest/ApiRemoteCompatCommand.swift": ["wantRuntime: false"],
        ])
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
