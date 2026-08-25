// ディープリンクの URL スキームが「契約 → 5 SUT の登録元」まで一致していることの走査。
//
// **URL スキームは SUT ごとに固有**(2026-08-09〜。iOS は同一カスタムスキームを複数アプリが登録
// していても解決先を1つしか選ばず、共有スキームだと別アプリへ配送される事故が実測された)。
// このテストは契約(E2EAppCMP/docs/ui-contract.md §ディープリンクの SUT 表)から SUT ごとの
// スキームを採り、各 SUT の登録元にそのスキームが在ることを確認する。加えて、スキームが
// SUT 間で重複していないこと(= 今回の事故そのもの)も検査する。
//
// **iOS の登録元は SUT で違う**: xcodegen を使う SUT(E2EAppCMP / E2EAppIOS)は
// `project.yml` の `info.properties` が生成元で、`Info.plist` は**毎ビルド上書きされる生成物**。
// plist を直接編集すると「コミットもビルドも単体テストも緑のまま、次のビルドで消える」
// (2026-08-08 に E2EAppCMP で実際に踏み、生成物の Info.plist を直接検査するまで気付けなかった)。
// だからこのテストは plist ではなく **project.yml を見る**。

import XCTest

final class DeepLinkSchemeSyncTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FleetestTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// スキームを登録する**生成元**。plist が生成物の SUT はここに project.yml を書く。
    /// 契約表の SUT 名(`E2EAppCMP` 等)をキーにする
    private static let registrationSources: [String: [String]] = [
        "E2EAppCMP": [
            "E2EAppCMP/iosApp/project.yml",
            "E2EAppCMP/composeApp/src/androidMain/AndroidManifest.xml",
        ],
        "E2EAppIOS": [
            "E2EAppIOS/project.yml",
        ],
        "E2EAppAndroid": [
            "E2EAppAndroid/app/src/main/AndroidManifest.xml",
        ],
        "E2EAppFlutter": [
            "E2EAppFlutter/ios/Runner/Info.plist",
            "E2EAppFlutter/android/app/src/main/AndroidManifest.xml",
        ],
        "E2EAppRN": [
            "E2EAppRN/ios/FTE2ERN/Info.plist",
            "E2EAppRN/android/app/src/main/AndroidManifest.xml",
        ],
    ]

    /// xcodegen が生成する Info.plist(= 編集しても消える側)。**追跡しない**ことで
    /// 「編集が残ったように見える」状態自体を作らない
    private static let generatedPlists = [
        "E2EAppCMP/iosApp/iosApp/Info.plist",
        "E2EAppIOS/Sources/Info.plist",
    ]

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 契約の SUT 表(§ディープリンク)が宣言している SUT → スキームの対応(唯一の正)。
    /// 表の行は `| \`SUT名\` | \`アプリID\` | \`スキーム\` |` の形
    private func contractSchemes() throws -> [String: String] {
        let contract = try contents("E2EAppCMP/docs/ui-contract.md")
        var result: [String: String] = [:]
        for line in contract.split(separator: "\n") {
            guard line.hasPrefix("| `E2EApp") else { continue }
            let columns = line.split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            }
            guard columns.count >= 3 else { continue }
            result[columns[0]] = columns[2]
        }
        XCTAssertFalse(result.isEmpty, "契約から SUT ごとのスキーム表を採れません(§ディープリンクの記法が変わった)")
        return result
    }

    func testEverySUTRegistersItsOwnContractScheme() throws {
        let schemes = try contractSchemes()
        for (sut, sources) in Self.registrationSources {
            guard let scheme = schemes[sut] else {
                XCTFail("契約の SUT 表に \(sut) がありません")
                continue
            }
            for source in sources {
                let text = try contents(source)
                XCTAssertTrue(text.contains(scheme),
                              "\(source) にスキーム \(scheme) の登録がありません。"
                                  + "iOS で xcodegen を使う SUT は Info.plist ではなく project.yml が生成元です")
            }
        }
    }

    /// 今回の事故(全 SUT 共通スキームで iOS の解決先が不定になった)そのものを落とす
    func testSchemesAreUniquePerSUT() throws {
        let schemes = try contractSchemes()
        var seenBy: [String: String] = [:]  // scheme -> 最初に見つけた SUT
        for (sut, scheme) in schemes {
            if let owner = seenBy[scheme] {
                XCTFail("スキーム \(scheme) が \(owner) と \(sut) で重複しています(SUT ごとに固有にすること)")
            } else {
                seenBy[scheme] = sut
            }
        }
    }

    /// 生成物の plist を追跡し直すと、また「編集したのに消える」に戻る
    func testGeneratedPlistsStayUntracked() throws {
        for plist in Self.generatedPlists {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", Self.repoRoot.path, "ls-files", "--error-unmatch", plist]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertNotEqual(process.terminationStatus, 0,
                              "\(plist) は xcodegen の生成物なので追跡しないこと"
                                  + "(追跡すると直接編集が durable に見えて次のビルドで消える)")
        }
    }
}
