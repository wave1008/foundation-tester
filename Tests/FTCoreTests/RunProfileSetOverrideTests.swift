// `fleetest run --set <key>=<true|false>` / `fleetest api run --set` の共有実装。
// キーはプロファイル JSON のキーそのもの(kebab 変換しない)。片方だけに足す変更を防ぐため
// 適用ロジックは RunProfileDocument.applyingOverrides の1箇所(FTCore/RunProfile.swift)。

import XCTest
@testable import FTCore

final class RunProfileSetOverrideParseTests: XCTestCase {

    func testParsesMultipleValidTokens() throws {
        let overrides = try RunProfileSetOverride.parse(["heal=true", "falsePositiveCheck=false"])
        XCTAssertEqual(overrides, ["heal": true, "falsePositiveCheck": false])
    }

    func testLaterDuplicateKeyWins() throws {
        let overrides = try RunProfileSetOverride.parse(["heal=true", "heal=false"])
        XCTAssertEqual(overrides, ["heal": false])
    }

    func testEmptyTokensYieldEmptyOverrides() throws {
        XCTAssertEqual(try RunProfileSetOverride.parse([]), [:])
    }

    func testRejectsTokenWithNoEqualsSign() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["heal"])) { error in
            guard case RunProfileSetOverrideError.invalidFormat(let token) = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
            XCTAssertEqual(token, "heal")
        }
    }

    /// 値は true/false のみ(大文字・yes/no 等は弾く)
    func testRejectsNonBooleanValue() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["heal=yes"])) { error in
            guard case RunProfileSetOverrideError.invalidValue(let key, let value) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(key, "heal")
            XCTAssertEqual(value, "yes")
        }
    }

    /// **未知キーは即エラーにし、有効なキーの一覧をメッセージに出す**(黙って無視しない)
    func testRejectsUnknownKeyAndListsAvailableOnes() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["bogusKey=true"])) { error in
            guard case RunProfileSetOverrideError.unknownKey(let key, let available) = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
            XCTAssertEqual(key, "bogusKey")
            XCTAssertEqual(Set(available), RunProfileDocument.overridableBoolKeys)
            XCTAssertTrue(error.localizedDescription.contains("heal"),
                          "メッセージにキー一覧が出ていない: \(error.localizedDescription)")
        }
    }

    /// `screenIs`(旧名の受け口)は Bool 欄ではあるが `--set` からは書けない
    /// (新キー screenLooksLike に一本化済み。testOverridableKeysMatchAllBoolFieldsExceptTheLegacyAlias 参照)
    func testScreenIsIsNotAnAcceptedSetKey() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["screenIs=true"])) { error in
            guard case RunProfileSetOverrideError.unknownKey = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
        }
    }
}

final class RunProfileSetOverrideKeysTests: XCTestCase {

    /// 全 Bool? 欄を非 nil にした最小のフィクスチャ(Mirror は nil の Optional を検出できないため。
    /// ElementInfoCodingTests と同じ手段)
    private func fullyPopulatedBoolDocument() -> RunProfileDocument {
        RunProfileDocument(
            app: "a", devices: [RunDeviceRef(name: "d")],
            fm: true, heal: true, falsePositiveCheck: true, screenLooksLike: true,
            ocr: true, ocrFalsePositiveCheck: true, triage: true,
            screenIs: true,
            machine: "m", iosInappEngine: true,
            wipeDataOnBloat: true, updateWebView: true,
            recoverCpuFallbackToGpu: true,
            locale: "ja_JP", iosFastInput: true, iosPreActionWarmup: true,
            containerInference: true,
            enableAnimations: true, homeOnStart: true,
            playProtectBypass: true, record: true,
            recordFailuresOnly: true, recordBitrateKbps: 1500,
            recordFullResolution: true)
    }

    /// `RunProfileDocument` の Bool? 欄と `--set` が受け付けるキーは**等号で一致する**こと
    /// (新しい Bool キーを足したのに `--set` から漏れる、を落とす)。**`screenIs` だけ意図的に
    /// 除外**する —— 新キー `screenLooksLike` に一本化済みで、実行プロファイルのチェックボックス
    /// (20個)にも無い旧名の受け口
    func testOverridableKeysMatchAllBoolFieldsExceptTheLegacyAlias() {
        // **`is Bool` ではなく文字列表現で判定する** —— Optional<Bool> を Any へ格納したときの
        // 動的キャストの unwrap 挙動に依存させない(String(describing:) は Bool だけが
        // 厳密に "true"/"false" を返す。RunProfileDocument の他の型(String/Int/Double/配列)は
        // どれもこの2値と一致しない)
        let boolFields = Set(Mirror(reflecting: fullyPopulatedBoolDocument()).children
            .compactMap { child -> String? in
                guard let label = child.label else { return nil }
                // Any へ入れた Optional<Bool> は "Optional(true)" になるので剥がしてから見る
                var description = String(describing: child.value)
                if description.hasPrefix("Optional("), description.hasSuffix(")") {
                    description = String(description.dropFirst("Optional(".count).dropLast())
                }
                return (description == "true" || description == "false") ? label : nil
            })
        XCTAssertTrue(boolFields.contains("screenIs"),
                      "フィクスチャが screenIs を埋め忘れている(このテストの前提が壊れる)")
        XCTAssertEqual(boolFields.subtracting(["screenIs"]), RunProfileDocument.overridableBoolKeys)
    }

    /// devices 依存キー(profileOnlyBoolKeys)は受け付けるキーの真部分集合であること
    /// (RunScenarios.validate/ApiRunCommand.run が「--profile が無いと弾く」対象として使う)。
    /// `homeOnStart`/`record`/`recordFailuresOnly`/`recordFullResolution` はここに**無い** ——
    /// devices への前処理ではなく workers に対して働くだけなので profile-less でも配線できる
    /// (record だけ別途 recordNeedsRejecting で経路を見て弾く。下のテスト参照)
    func testProfileOnlyKeysAreASubsetOfOverridableKeys() {
        XCTAssertTrue(RunProfileDocument.profileOnlyBoolKeys.isSubset(of: RunProfileDocument.overridableBoolKeys))
        XCTAssertEqual(RunProfileDocument.profileOnlyBoolKeys, [
            "iosInappEngine", "updateWebView", "wipeDataOnBloat", "recoverCpuFallbackToGpu",
        ])
    }

    /// `record:true` は RunOrchestrator の録画セッションを経由する実行だけ許す
    /// (Fleetest.swift の runSequential/runParallel 分岐・ApiRunCommand.swift の runDirect が
    /// hasRecordingSession を渡す)。record:false はセッションの有無に関わらず常に素通り
    func testRecordNeedsRejectingOnlyWhenRecordingIsRequestedWithoutASession() {
        XCTAssertTrue(RunProfileDocument.recordNeedsRejecting(record: true, hasRecordingSession: false))
        XCTAssertFalse(RunProfileDocument.recordNeedsRejecting(record: true, hasRecordingSession: true))
        XCTAssertFalse(RunProfileDocument.recordNeedsRejecting(record: false, hasRecordingSession: false))
        XCTAssertFalse(RunProfileDocument.recordNeedsRejecting(record: false, hasRecordingSession: true))
    }
}

final class RunProfileDocumentApplyingOverridesTests: XCTestCase {

    func testEmptyOverridesReturnsTheSameValues() {
        let doc = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")], heal: true)
        XCTAssertEqual(doc.applyingOverrides([:]), doc)
    }

    func testOverridesEachSupportedKey() {
        var overrides: [String: Bool] = [:]
        for (index, key) in RunProfileDocument.overridableBoolKeys.sorted().enumerated() {
            overrides[key] = index.isMultiple(of: 2)
        }
        let applied = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")])
            .applyingOverrides(overrides)
        for (key, value) in overrides {
            XCTAssertEqual(boolField(applied, key), value, "\(key) が上書きされていない")
        }
    }

    /// 未知キーは(CLI 側で既に弾いている前提のもと)防御的に無視するだけで落ちない
    func testUnknownKeyIsIgnoredDefensively() {
        let doc = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")])
        let applied = doc.applyingOverrides(["notAKey": true])
        XCTAssertEqual(applied, doc)
    }

    /// キーの読み出しを1箇所に集約する(テストの可読性のためだけの小道具。本体の switch と
    /// 二重管理になるが、こちらは「反映されたか」を機械的に確かめるだけなので許容する)
    private func boolField(_ doc: RunProfileDocument, _ key: String) -> Bool? {
        switch key {
        case "fm": return doc.fm
        case "heal": return doc.heal
        case "falsePositiveCheck": return doc.falsePositiveCheck
        case "triage": return doc.triage
        case "screenLooksLike": return doc.screenLooksLike
        case "ocr": return doc.ocr
        case "ocrFalsePositiveCheck": return doc.ocrFalsePositiveCheck
        case "iosInappEngine": return doc.iosInappEngine
        case "iosFastInput": return doc.iosFastInput
        case "iosPreActionWarmup": return doc.iosPreActionWarmup
        case "containerInference": return doc.containerInference
        case "enableAnimations": return doc.enableAnimations
        case "homeOnStart": return doc.homeOnStart
        case "playProtectBypass": return doc.playProtectBypass
        case "updateWebView": return doc.updateWebView
        case "wipeDataOnBloat": return doc.wipeDataOnBloat
        case "recoverCpuFallbackToGpu": return doc.recoverCpuFallbackToGpu
        case "record": return doc.record
        case "recordFailuresOnly": return doc.recordFailuresOnly
        case "recordFullResolution": return doc.recordFullResolution
        default:
            XCTFail("boolField に未対応のキー: \(key)")
            return nil
        }
    }
}

final class DeviceIndependentRunSettingsTests: XCTestCase {

    func testDefaultsMatchTheRunProfileDocumentDefaults() {
        let settings = DeviceIndependentRunSettings.resolve(RunProfileDocument())
        XCTAssertEqual(settings.fm, FMConfig(enabled: true, heal: true, falsePositiveCheck: true,
                                             screenLooksLike: true, triage: true))
        XCTAssertTrue(settings.ocr)
        XCTAssertTrue(settings.ocrFalsePositiveCheck)
        XCTAssertFalse(settings.iosFastInput)
        XCTAssertTrue(settings.iosPreActionWarmup)
        XCTAssertTrue(settings.containerInference)
        XCTAssertFalse(settings.enableAnimations)
        XCTAssertTrue(settings.playProtectBypass)
        XCTAssertTrue(settings.homeOnStart)
        XCTAssertFalse(settings.record)
        XCTAssertFalse(settings.recordFailuresOnly)
        XCTAssertFalse(settings.recordFullResolution)
    }

    /// `--set` の上書きが `DeviceIndependentRunSettings` を経由して profile-less 経路まで届くこと
    /// (record/recordFailuresOnly/recordFullResolution/homeOnStart は --profile 無しでも
    /// resolve() の中で読まれる。resolve() が読み忘れると常に既定値のまま変わらず落ちる)
    func testRecordAndHomeOnStartOverridesFlowThroughResolve() {
        let doc = RunProfileDocument().applyingOverrides([
            "record": true, "recordFailuresOnly": true, "recordFullResolution": true,
            "homeOnStart": false,
        ])
        let settings = DeviceIndependentRunSettings.resolve(doc)
        XCTAssertTrue(settings.record)
        XCTAssertTrue(settings.recordFailuresOnly)
        XCTAssertTrue(settings.recordFullResolution)
        XCTAssertFalse(settings.homeOnStart)
    }

    /// fm:false は heal/falsePositiveCheck/screenLooksLike/triage を無条件に false へ落とす
    /// (`--set fm=false --set heal=true` としても heal は立たない)
    func testFmFalseGatesTheOtherFMTogglesEvenWhenTheyAreExplicitlyTrue() {
        let doc = RunProfileDocument().applyingOverrides(["fm": false, "heal": true])
        let settings = DeviceIndependentRunSettings.resolve(doc)
        XCTAssertFalse(settings.fm.enabled)
        XCTAssertFalse(settings.fm.heal, "fm:false のときは heal:true を指定しても立たない")
    }

    /// ocr:false は ocrFalsePositiveCheck を無条件に false へ落とす(fm と同じ契約)
    func testOcrFalseGatesOcrFalsePositiveCheck() {
        let doc = RunProfileDocument().applyingOverrides(["ocr": false, "ocrFalsePositiveCheck": true])
        let settings = DeviceIndependentRunSettings.resolve(doc)
        XCTAssertFalse(settings.ocr)
        XCTAssertFalse(settings.ocrFalsePositiveCheck)
    }
}

/// `ProfileResolver.resolve(overrides:)` が実際にプロファイル解決へ反映されること
/// (単体の適用ロジックは上の *ApplyingOverrides* / *DeviceIndependentRunSettings* が固定するので、
/// ここでは「resolve() のこの引数を通ると効く」という配線だけを見る)
final class ProfileResolverOverridesIntegrationTests: XCTestCase {
    var tempDir: URL!
    var project: TestProject!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTCoreTests-\(UUID().uuidString)")
        let root = tempDir.appendingPathComponent("TestProjects/SampleApp")
        project = TestProject(name: "SampleApp", rootURL: root)
        for dir in [project.appsDir, project.machinesDir, project.runsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try """
        { "ios": { "app": "com.example.sampleapp" } }
        """.data(using: .utf8)!.write(to: project.appsDir.appendingPathComponent("sampleapp.json"))
        try """
        { "ios": { "devices": [ { "name": "メイン機", "simulator": "iPhone 17 Pro" } ] } }
        """.data(using: .utf8)!.write(to: project.machinesDir.appendingPathComponent("m.json"))
        try """
        { "app": "sampleapp", "devices": [ { "name": "メイン機" } ], "heal": true }
        """.data(using: .utf8)!.write(to: project.runsDir.appendingPathComponent("r.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// プロファイルが明示 `heal: true` でも `--set heal=false` が勝つ
    func testSetOverrideBeatsTheProfilesOwnValue() throws {
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m", overrides: ["heal": false])
        XCTAssertFalse(resolved.heal)
    }

    /// プロファイルが触れていないキーは `--set` で自由に上書きできる(既定 true の
    /// playProtectBypass を明示的に切る)
    func testSetOverrideAppliesToAKeyTheProfileDoesNotMention() throws {
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m", overrides: ["playProtectBypass": false])
        XCTAssertFalse(resolved.playProtectBypass)
    }

    /// overrides を渡さなければ従来どおり(後方互換。呼び出しのほとんどが該当する)
    func testOmittingOverridesKeepsThePreviousBehaviour() throws {
        let resolved = try ProfileResolver.resolve(project: project, runName: "r", machineName: "m")
        XCTAssertTrue(resolved.heal)
    }

    /// `record`/`homeOnStart` は `DeviceIndependentRunSettings` 経由で読む(runDoc から直接
    /// 読み直す退行を防ぐ。--profile があってもこの2つは devices に依存しないのでどちらの
    /// 経路でも同じ関数を通る)
    func testSetOverrideAppliesToRecordAndHomeOnStartWithAProfile() throws {
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m",
            overrides: ["record": true, "homeOnStart": false])
        XCTAssertTrue(resolved.record)
        XCTAssertFalse(resolved.homeOnStart)
    }
}
