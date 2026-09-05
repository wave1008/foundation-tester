// シナリオ選択(`fleetest run <id>...` / `--folder`)の解決規則。
// 「指定したのに実行されない」「@Deleted が勝手に走る」は利用者から見て最も分かりにくい壊れ方で、
// かつ選択が間違っていても選ばれたシナリオ自体は成功するため E2E では捕まらない。

import XCTest
import FTCore
@testable import fleetest

final class ScenarioSelectionTests: XCTestCase {

    private func info(_ id: String, deleted: Bool = false, draft: Bool = false) -> ScenarioInfo {
        ScenarioInfo(id: id, title: id, app: "SampleApp", platform: nil, deleted: deleted, draft: draft)
    }

    private lazy var all: [ScenarioInfo] = [
        info("ログインテスト.S0010"),
        info("ログインテスト.S0020"),
        info("ログインテスト.S0030", deleted: true),
        info("設定画面.S0010"),
    ]

    // MARK: - resolve

    func testEmptySelectionRunsEverythingExceptDeleted() throws {
        // 無指定=全実行。@Deleted は下書き(セレクタが TODO のまま)なので必ず除く
        let result = try RunScenarios.resolve([], from: all)
        XCTAssertEqual(result.map(\.id),
                       ["ログインテスト.S0010", "ログインテスト.S0020", "設定画面.S0010"])
    }

    func testExactIDIsSelectedEvenWhenDeleted() throws {
        // 完全指定は @Deleted でも実行できる(下書きを個別に試す運用のため)
        let result = try RunScenarios.resolve(["ログインテスト.S0030"], from: all)
        XCTAssertEqual(result.map(\.id), ["ログインテスト.S0030"])
    }

    func testClassNameExpandsToItsScenariosExcludingDeleted() throws {
        let result = try RunScenarios.resolve(["ログインテスト"], from: all)
        XCTAssertEqual(result.map(\.id), ["ログインテスト.S0010", "ログインテスト.S0020"],
                       "クラス指定では @Deleted を含めない")
    }

    func testMultipleSelectorsArePreservedInOrder() throws {
        let result = try RunScenarios.resolve(["設定画面.S0010", "ログインテスト"], from: all)
        XCTAssertEqual(result.map(\.id),
                       ["設定画面.S0010", "ログインテスト.S0010", "ログインテスト.S0020"],
                       "指定順を保つ")
    }

    func testUnknownIDThrowsWithAvailableList() {
        XCTAssertThrowsError(try RunScenarios.resolve(["知らないやつ"], from: all)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("知らないやつ"), message)
            // 利用可能一覧を出さないと、利用者は正しい ID を推測できない
            XCTAssertTrue(message.contains("ログインテスト.S0010"), message)
        }
    }

    /// **打ち間違いと誤解させない**: `_disabled`(コンパイル対象外)に同名クラスがあれば、
    /// 「無い」ではなくその在処を名指しする(2026-09-05・実測で「無い」と誤解された)
    func testUnknownIDNamesTheQuarantineFileWhenPresent() throws {
        let dir = try makeScenariosDir(["_disabled": ["クラッシュ検知"]])
        XCTAssertThrowsError(
            try RunScenarios.resolve(["クラッシュ検知.S0010"], from: all, scenariosDir: dir)
        ) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("scenarios/_disabled/クラッシュ検知.swift"), message)
            XCTAssertTrue(message.contains("excluded from compilation"), message)
        }
    }

    /// scenariosDir を渡さない呼び出し元(profile/fleet 経由)は従来文のまま
    func testUnknownIDWithoutScenariosDirKeepsTheTraditionalMessage() {
        XCTAssertThrowsError(try RunScenarios.resolve(["知らないやつ"], from: all)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("available:"), message)
        }
    }

    func testClassWhoseScenariosAreAllDeletedThrowsDistinctMessage() {
        // 「見つからない」ではなく「全て削除済み」と言い分ける(原因が違うため)
        let onlyDeleted = [info("下書き.S0010", deleted: true)]
        XCTAssertThrowsError(try RunScenarios.resolve(["下書き"], from: onlyDeleted)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("deleted"), message)
            XCTAssertTrue(message.contains("exact Class.method"), "回避方法を示すこと: \(message)")
        }
    }

    // MARK: - @Draft

    func testEmptySelectionExcludesDraft() throws {
        let withDraft = all + [info("実装中.S0010", draft: true)]
        let result = try RunScenarios.resolve([], from: withDraft)
        XCTAssertFalse(result.map(\.id).contains("実装中.S0010"))
    }

    func testExactIDIsSelectedEvenWhenDraft() throws {
        // 完全指定は @Draft でも実行できる(実装しながら個別に試す運用のため)
        let withDraft = all + [info("実装中.S0010", draft: true)]
        let result = try RunScenarios.resolve(["実装中.S0010"], from: withDraft)
        XCTAssertEqual(result.map(\.id), ["実装中.S0010"])
    }

    func testClassNameExpandsToItsScenariosExcludingDraft() throws {
        let withDraft = [info("実装中.S0010"), info("実装中.S0020", draft: true)]
        let result = try RunScenarios.resolve(["実装中"], from: withDraft)
        XCTAssertEqual(result.map(\.id), ["実装中.S0010"], "クラス指定では @Draft を含めない")
    }

    func testClassWhoseScenariosAreAllDraftThrowsMessageMentioningDraft() {
        let onlyDraft = [info("実装中.S0010", draft: true)]
        XCTAssertThrowsError(try RunScenarios.resolve(["実装中"], from: onlyDraft)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("draft"), message)
            XCTAssertTrue(message.contains("exact Class.method"), "回避方法を示すこと: \(message)")
        }
    }

    func testPrefixDoesNotMatchWithoutDotBoundary() throws {
        // "ログイン" が "ログインテスト.S0010" を巻き込まない(区切りは "." のみ)
        XCTAssertThrowsError(try RunScenarios.resolve(["ログイン"], from: all))
    }

    // MARK: - filterByFolders

    private var tempDir: URL!

    private func makeScenariosDir(_ layout: [String: [String]]) throws -> URL {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FleetestTests-\(UUID().uuidString)")
        let scenariosDir = tempDir.appendingPathComponent("scenarios")
        for (folder, classNames) in layout {
            let dir = folder.isEmpty ? scenariosDir : scenariosDir.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for className in classNames {
                let source = "@TestClass(app: \"SampleApp\")\nclass \(className) {}\n"
                try Data(source.utf8).write(to: dir.appendingPathComponent("\(className).swift"))
            }
        }
        return scenariosDir
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testFilterByFoldersKeepsOnlyScenariosInNamedFolders() throws {
        let dir = try makeScenariosDir(["ログイン": ["LoginTests"], "設定": ["SettingsTests"]])
        let infos = [info("LoginTests.S0010"), info("SettingsTests.S0010")]

        let result = try RunScenarios.filterByFolders(infos, folders: ["ログイン"], scenariosDir: dir)
        XCTAssertEqual(result.map(\.id), ["LoginTests.S0010"])
    }

    func testFilterByFoldersAcceptsMultipleFolders() throws {
        let dir = try makeScenariosDir(["ログイン": ["LoginTests"], "設定": ["SettingsTests"]])
        let infos = [info("LoginTests.S0010"), info("SettingsTests.S0010")]

        let result = try RunScenarios.filterByFolders(infos, folders: ["ログイン", "設定"],
                                                      scenariosDir: dir)
        XCTAssertEqual(Set(result.map(\.id)), ["LoginTests.S0010", "SettingsTests.S0010"])
    }

    func testUnknownFolderThrowsWithAvailableList() throws {
        let dir = try makeScenariosDir(["ログイン": ["LoginTests"]])
        let infos = [info("LoginTests.S0010")]

        XCTAssertThrowsError(
            try RunScenarios.filterByFolders(infos, folders: ["存在しない"], scenariosDir: dir)
        ) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("存在しない"), "見つからないフォルダ名をエコーすること: \(message)")
            XCTAssertTrue(message.contains("ログイン"), "利用可能なフォルダを出すこと: \(message)")
        }
    }

    func testKnownFolderWithNoMatchingScenarioReturnsEmptyWithoutThrowing() throws {
        // フォルダ名は正しいが該当シナリオが無い場合は「0件」であってエラーではない
        let dir = try makeScenariosDir(["ログイン": ["LoginTests"], "空": []])
        let infos = [info("LoginTests.S0010")]

        let result = try RunScenarios.filterByFolders(infos, folders: ["空"], scenariosDir: dir)
        XCTAssertTrue(result.isEmpty)
    }
}
