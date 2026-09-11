// `fleetest run --set <key>=<value>` / `fleetest api run --set` の共有実装。
// キーはプロファイル JSON のキーそのもの(kebab 変換しない)。値の型はキーの宣言型に従う
// (Bool/Int/Double/String)。片方だけに足す変更を防ぐため適用ロジックは
// RunProfileDocument.applyingOverrides の1箇所(FTCore/RunProfile.swift)。

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

    /// bool 欄の値は true/false のみ(大文字・yes/no 等は弾く)
    func testRejectsNonBooleanValue() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["heal=yes"])) { error in
            guard case RunProfileSetOverrideError.invalidValue(let key, let value, let expected) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(key, "heal")
            XCTAssertEqual(value, "yes")
            XCTAssertEqual(expected, .bool)
            XCTAssertTrue(error.localizedDescription.contains("\"true\" or \"false\""),
                          error.localizedDescription)
        }
    }

    /// int 欄(scenarioTimeout/recordBitrateKbps)は整数のみ。小数・非数値は型を名指しして弾く
    func testRejectsNonIntegerValueForAnIntKey() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["scenarioTimeout=12.5"])) { error in
            guard case RunProfileSetOverrideError.invalidValue(let key, let value, let expected) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(key, "scenarioTimeout")
            XCTAssertEqual(value, "12.5")
            XCTAssertEqual(expected, .int)
            XCTAssertTrue(error.localizedDescription.contains("an integer"), error.localizedDescription)
        }
    }

    /// double 欄(defaultTimeout/wipeDataThresholdGB)は数値のみ。非数値は型を名指しして弾く
    /// (整数の文字列("8")は Double にも通ることを別テストで確認する)
    func testRejectsNonNumericValueForADoubleKey() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["defaultTimeout=fast"])) { error in
            guard case RunProfileSetOverrideError.invalidValue(let key, let value, let expected) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(key, "defaultTimeout")
            XCTAssertEqual(value, "fast")
            XCTAssertEqual(expected, .double)
            XCTAssertTrue(error.localizedDescription.contains("a number"), error.localizedDescription)
        }
    }

    /// int/double 欄の成功パース(型ごとの成功系はここでまとめて確認する)
    func testParsesScalarKeysOfEachDeclaredType() throws {
        let overrides = try RunProfileSetOverride.parse([
            "reportDir=/tmp/out", "defaultTimeout=7.5", "scenarioTimeout=45",
            "recordBitrateKbps=2000", "app=sample-app", "machine=m1",
            "locale=en_US", "wipeDataThresholdGB=4",
        ])
        XCTAssertEqual(overrides, [
            "reportDir": .string("/tmp/out"), "defaultTimeout": .double(7.5),
            "scenarioTimeout": .int(45), "recordBitrateKbps": .int(2000),
            "app": .string("sample-app"), "machine": .string("m1"),
            "locale": .string("en_US"), "wipeDataThresholdGB": .double(4),
        ])
    }

    /// string 欄は何を渡しても成功する(パース失敗が起きようがない)
    func testStringKeyNeverFailsToParse() throws {
        let overrides = try RunProfileSetOverride.parse(["reportDir="])
        XCTAssertEqual(overrides, ["reportDir": .string("")])
    }

    /// **未知キーは即エラーにし、有効なキーの一覧をメッセージに出す**(黙って無視しない)
    func testRejectsUnknownKeyAndListsAvailableOnes() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["bogusKey=true"])) { error in
            guard case RunProfileSetOverrideError.unknownKey(let key, let available) = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
            XCTAssertEqual(key, "bogusKey")
            XCTAssertEqual(Set(available), RunProfileDocument.overridableKeys)
            XCTAssertTrue(error.localizedDescription.contains("heal"),
                          "メッセージにキー一覧が出ていない: \(error.localizedDescription)")
        }
    }

    /// `screenIs`(旧名の受け口)は Bool 欄ではあるが `--set` からは書けない
    /// (新キー screenLooksLike に一本化済み。testOverridableKeysMatchAllFieldsExceptExcluded 参照)
    func testScreenIsIsNotAnAcceptedSetKey() {
        XCTAssertThrowsError(try RunProfileSetOverride.parse(["screenIs=true"])) { error in
            guard case RunProfileSetOverrideError.unknownKey = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
        }
    }

    /// `devices`/`remoteControl`(配列・オブジェクト)は「未知のキー」ではなく専用のメッセージで
    /// 断る —— 利用者が `<key>=<value>` で書けると誤解しないよう、プロファイル JSON を編集する
    /// よう案内する
    func testArrayAndObjectKeysGetADedicatedError() {
        for key in ["devices", "remoteControl"] {
            XCTAssertThrowsError(try RunProfileSetOverride.parse(["\(key)=x"])) { error in
                guard case RunProfileSetOverrideError.arrayOrObjectKey(let reportedKey) = error else {
                    return XCTFail("expected arrayOrObjectKey for \(key), got \(error)")
                }
                XCTAssertEqual(reportedKey, key)
                XCTAssertTrue(error.localizedDescription.contains("edit the run profile JSON"),
                              error.localizedDescription)
            }
        }
    }

    // MARK: - scenarioTimeout/defaultTimeout の範囲外値(負値・0・NaN)を弾く

    func testRejectsZeroOrNegativeScenarioTimeout() {
        for bad in ["0", "-5"] {
            XCTAssertThrowsError(try RunProfileSetOverride.parse(["scenarioTimeout=\(bad)"])) { error in
                guard case RunProfileSetOverrideError.outOfRange(let key, let value, let reason) = error else {
                    return XCTFail("expected outOfRange for scenarioTimeout=\(bad), got \(error)")
                }
                XCTAssertEqual(key, "scenarioTimeout")
                XCTAssertEqual(value, bad)
                XCTAssertTrue(reason.contains("positive"), reason)
            }
        }
    }

    func testRejectsZeroNegativeOrNaNDefaultTimeout() {
        for bad in ["0", "-1.5", "nan"] {
            XCTAssertThrowsError(try RunProfileSetOverride.parse(["defaultTimeout=\(bad)"])) { error in
                guard case RunProfileSetOverrideError.outOfRange(let key, let value, _) = error else {
                    return XCTFail("expected outOfRange for defaultTimeout=\(bad), got \(error)")
                }
                XCTAssertEqual(key, "defaultTimeout")
                XCTAssertEqual(value, bad)
            }
        }
    }

    /// 正の値は従来どおり通る(範囲チェックが健全な値まで弾いていないことの対照)
    func testPositiveScenarioAndDefaultTimeoutStillParse() throws {
        let overrides = try RunProfileSetOverride.parse(["scenarioTimeout=45", "defaultTimeout=7.5"])
        XCTAssertEqual(overrides["scenarioTimeout"], .int(45))
        XCTAssertEqual(overrides["defaultTimeout"], .double(7.5))
    }

    /// `--set <key>=<token>` の再構成(RemoteRunArgs/FleetRunner/ApiRunMachineFanout が子プロセスへ
    /// 中継するときに使う)は parse() の逆変換になっている(round-trip)
    func testTokenRoundTripsThroughParse() throws {
        let cases: [(String, RunProfileSetValue)] = [
            ("heal", .bool(true)), ("heal", .bool(false)),
            ("scenarioTimeout", .int(45)), ("defaultTimeout", .double(7.5)),
            ("reportDir", .string("/tmp/out")),
        ]
        for (key, value) in cases {
            let reparsed = try RunProfileSetOverride.parse(["\(key)=\(value.token)"])
            XCTAssertEqual(reparsed[key], value, "\(key)=\(value.token) が round-trip しない")
        }
    }
}

final class RunProfileSetOverrideKeysTests: XCTestCase {

    /// `RunProfileDocument` の各欄の宣言型を Mirror で分類する。**値の有無ではなく静的な型**で
    /// 決まる(Optional のまま Any へ入るため —— 空の `RunProfileDocument()` で十分。
    /// `Bool(true)`/`nil` のどちらでも `type(of:)` は同じ `Optional<Bool>` になる)
    private func fieldKind(_ value: Any) -> String {
        let dynamicType = type(of: value)
        if dynamicType == Optional<Bool>.self { return "bool" }
        if dynamicType == Optional<Int>.self { return "int" }
        if dynamicType == Optional<Double>.self { return "double" }
        if dynamicType == Optional<String>.self { return "string" }
        return "other"
    }

    private func fieldsByKind() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for child in Mirror(reflecting: RunProfileDocument()).children {
            guard let label = child.label else { continue }
            result[fieldKind(child.value), default: []].insert(label)
        }
        return result
    }

    /// `RunProfileDocument` の Bool/Int/Double/String 欄と `--set` が受け付けるキーは
    /// **等号で一致する**こと(新しいスカラー欄を足したのに `--set` から漏れる、を落とす)。
    /// **`screenIs` だけ意図的に除外**する(新キー `screenLooksLike` に一本化済み)。
    /// **`other`(配列・オブジェクト)は `devices`/`remoteControl` の2つだけであること**も固定する
    /// —— 新しい配列/オブジェクト欄が増えたときに、この等号でだけ検知されず黙って `--set` の
    /// 対象外になる(=気づかれない)のを防ぐ
    func testOverridableKeysMatchAllFieldsExceptExcluded() {
        let byKind = fieldsByKind()
        let scalarFields = (byKind["bool"] ?? [])
            .union(byKind["int"] ?? [])
            .union(byKind["double"] ?? [])
            .union(byKind["string"] ?? [])
        XCTAssertTrue((byKind["bool"] ?? []).contains("screenIs"),
                      "screenIs は Bool 欄のはず(このテストの前提が壊れる)")
        XCTAssertEqual(scalarFields.subtracting(["screenIs"]), RunProfileDocument.overridableKeys)
        XCTAssertEqual(byKind["other"] ?? [], ["devices", "remoteControl"],
                       "配列/オブジェクト欄が増減した —— --set から弾く/受け付ける対応を決めて"
                       + " arrayOrObjectKeys かこのテストの期待値を更新する")
    }

    /// devices/供給工程依存キー(profileOnlyKeys)は受け付けるキーの真部分集合であること
    /// (RunScenarios.validate/ApiRunCommand.run が「--profile が無いと弾く」対象として使う)。
    /// `homeOnStart`/`record`/`recordFailuresOnly`/`recordFullResolution`/`reportDir`/
    /// `defaultTimeout`/`scenarioTimeout`/`recordBitrateKbps` はここに**無い** ——
    /// devices への前処理ではなく workers/レポート出力先に対して働くだけなので profile-less でも
    /// 配線できる(record だけ別途 recordNeedsRejecting で経路を見て弾く。下のテスト参照)
    func testProfileOnlyKeysAreASubsetOfOverridableKeys() {
        XCTAssertTrue(RunProfileDocument.profileOnlyKeys.isSubset(of: RunProfileDocument.overridableKeys))
        XCTAssertEqual(RunProfileDocument.profileOnlyKeys, [
            "iosInappEngine", "updateWebView", "wipeDataOnBloat", "recoverCpuFallbackToGpu",
            "app", "machine", "locale", "wipeDataThresholdGB",
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

    /// 専用フラグと同じキーの `--set` は黙ってどちらかを勝たせない(nil = 衝突なし)
    func testFlagOverrideCollision() {
        XCTAssertNil(RunProfileDocument.flagOverrideCollision(
            flag: "--report-dir", key: "reportDir", flagIsSet: false, overrides: ["reportDir": .string("x")]))
        XCTAssertNil(RunProfileDocument.flagOverrideCollision(
            flag: "--report-dir", key: "reportDir", flagIsSet: true, overrides: [:]))
        guard let message = RunProfileDocument.flagOverrideCollision(
            flag: "--report-dir", key: "reportDir", flagIsSet: true,
            overrides: ["reportDir": .string("x")]) else {
            return XCTFail("expected a collision message")
        }
        XCTAssertTrue(message.contains("--report-dir"), message)
        XCTAssertTrue(message.contains("--set reportDir"), message)
    }
}

final class RunProfileDocumentApplyingOverridesTests: XCTestCase {

    /// キーの読み出しを1箇所に集約する(テストの可読性のためだけの小道具。本体の switch と
    /// 二重管理になるが、こちらは「反映されたか」を機械的に確かめるだけなので許容する)
    private func fieldValue(_ doc: RunProfileDocument, _ key: String) -> RunProfileSetValue? {
        switch key {
        case "fm": return doc.fm.map(RunProfileSetValue.bool)
        case "heal": return doc.heal.map(RunProfileSetValue.bool)
        case "falsePositiveCheck": return doc.falsePositiveCheck.map(RunProfileSetValue.bool)
        case "triage": return doc.triage.map(RunProfileSetValue.bool)
        case "screenLooksLike": return doc.screenLooksLike.map(RunProfileSetValue.bool)
        case "ocr": return doc.ocr.map(RunProfileSetValue.bool)
        case "ocrFalsePositiveCheck": return doc.ocrFalsePositiveCheck.map(RunProfileSetValue.bool)
        case "iosInappEngine": return doc.iosInappEngine.map(RunProfileSetValue.bool)
        case "iosFastInput": return doc.iosFastInput.map(RunProfileSetValue.bool)
        case "iosPreActionWarmup": return doc.iosPreActionWarmup.map(RunProfileSetValue.bool)
        case "containerInference": return doc.containerInference.map(RunProfileSetValue.bool)
        case "enableAnimations": return doc.enableAnimations.map(RunProfileSetValue.bool)
        case "homeOnStart": return doc.homeOnStart.map(RunProfileSetValue.bool)
        case "playProtectBypass": return doc.playProtectBypass.map(RunProfileSetValue.bool)
        case "updateWebView": return doc.updateWebView.map(RunProfileSetValue.bool)
        case "wipeDataOnBloat": return doc.wipeDataOnBloat.map(RunProfileSetValue.bool)
        case "recoverCpuFallbackToGpu": return doc.recoverCpuFallbackToGpu.map(RunProfileSetValue.bool)
        case "record": return doc.record.map(RunProfileSetValue.bool)
        case "recordFailuresOnly": return doc.recordFailuresOnly.map(RunProfileSetValue.bool)
        case "recordFullResolution": return doc.recordFullResolution.map(RunProfileSetValue.bool)
        case "reportDir": return doc.reportDir.map(RunProfileSetValue.string)
        case "defaultTimeout": return doc.defaultTimeout.map(RunProfileSetValue.double)
        case "scenarioTimeout": return doc.scenarioTimeout.map(RunProfileSetValue.int)
        case "recordBitrateKbps": return doc.recordBitrateKbps.map(RunProfileSetValue.int)
        case "app": return doc.app.map(RunProfileSetValue.string)
        case "machine": return doc.machine.map(RunProfileSetValue.string)
        case "locale": return doc.locale.map(RunProfileSetValue.string)
        case "wipeDataThresholdGB": return doc.wipeDataThresholdGB.map(RunProfileSetValue.double)
        default:
            XCTFail("fieldValue に未対応のキー: \(key)")
            return nil
        }
    }

    /// キーごとの見本値(型はキーの宣言型に一致させる)。`RunProfileSetOverride.parse` を通して
    /// 作るので、値の型は本体の宣言型マップと自動的に一致する(このテストが型を手で二重管理しない)
    private static let sampleRawValues: [String: String] = [
        "fm": "false", "heal": "false", "falsePositiveCheck": "false", "triage": "false",
        "screenLooksLike": "false", "ocr": "false", "ocrFalsePositiveCheck": "false",
        "iosInappEngine": "false", "iosFastInput": "true", "iosPreActionWarmup": "false",
        "containerInference": "false", "enableAnimations": "true", "homeOnStart": "false",
        "playProtectBypass": "false", "updateWebView": "false", "wipeDataOnBloat": "false",
        "recoverCpuFallbackToGpu": "true", "record": "true", "recordFailuresOnly": "true",
        "recordFullResolution": "true",
        "reportDir": "/tmp/out", "defaultTimeout": "12.5", "scenarioTimeout": "45",
        "recordBitrateKbps": "2000", "app": "sample-app", "machine": "m1",
        "locale": "en_US", "wipeDataThresholdGB": "4.5",
    ]

    func testEmptyOverridesReturnsTheSameValues() {
        let doc = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")], heal: true)
        XCTAssertEqual(doc.applyingOverrides([:]), doc)
    }

    /// 受け付ける全キー(Bool 20 + スカラー8)が実際に反映されること。壊れたキーだけ
    /// このテストで機械的に検知する(1件でも switch 分岐から漏れる/型を取り違えると落ちる)
    func testOverridesEachSupportedKey() throws {
        let tokens = RunProfileDocument.overridableKeys.sorted().map { key -> String in
            guard let raw = Self.sampleRawValues[key] else {
                XCTFail("\(key) の見本値が無い(sampleRawValues に追記すること)")
                return "\(key)=true"
            }
            return "\(key)=\(raw)"
        }
        let overrides = try RunProfileSetOverride.parse(tokens)
        XCTAssertEqual(Set(overrides.keys), RunProfileDocument.overridableKeys)
        let applied = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")])
            .applyingOverrides(overrides)
        for (key, value) in overrides {
            XCTAssertEqual(fieldValue(applied, key), value, "\(key) が上書きされていない")
        }
    }

    /// 未知キーは(CLI 側で既に弾いている前提のもと)防御的に無視するだけで落ちない
    func testUnknownKeyIsIgnoredDefensively() {
        let doc = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")])
        let applied = doc.applyingOverrides(["notAKey": true])
        XCTAssertEqual(applied, doc)
    }

    /// キーの宣言型と違う `RunProfileSetValue` ケース(`parse()` を経由しない直接構築でしか
    /// 起こらない)も防御的に無視する —— 本体の switch はタプルパターン `(key, .kind(v))` で
    /// マッチするので、型が合わなければどの case にも当たらず default で無視される
    func testWrongTypedValueIsIgnoredDefensively() {
        let doc = RunProfileDocument(app: "a", devices: [RunDeviceRef(name: "d")])
        let applied = doc.applyingOverrides(["heal": .string("true")])
        XCTAssertNil(applied.heal)
    }
}

final class DeviceIndependentRunSettingsTests: XCTestCase {

    /// **profile-less の基底はリテラルで固定する**。プロファイルの既定(heal/falsePositiveCheck
    /// はどちらも true)をそのまま使うと、素の `fleetest run` で occlusion-guard が走り始めて
    /// **既に緑だった run が赤に反転しうる**(2026-09-08 に実際に入れた退行)。homeOnStart も
    /// 同じで、既に建っているブリッジへ繋ぐだけの経路で手元の画面を Home で流してしまう。
    /// **`RunProfileDocument` の既定を参照して書かない** —— production の定数で期待値を書くと
    /// 両方が同時に動いたときに素通りする
    func testProfileLessBasePinsTheThreeDeliberateDifferences() {
        let base = DeviceIndependentRunSettings.profileLessBase
        XCTAssertEqual(base.heal, false, "profile-less の heal は OFF")
        XCTAssertEqual(base.falsePositiveCheck, false, "profile-less の偽陽性検証は OFF")
        XCTAssertEqual(base.homeOnStart, false, "profile-less はデバイスに触らない")

        // 残りはプロファイルの既定と同じであること(3つ以外を勝手に倒していない)
        let settings = DeviceIndependentRunSettings.resolve(base)
        XCTAssertTrue(settings.fm.enabled)
        XCTAssertTrue(settings.fm.screenLooksLike)
        XCTAssertTrue(settings.fm.triage)
        XCTAssertTrue(settings.ocr)
        XCTAssertTrue(settings.ocrFalsePositiveCheck)
        XCTAssertTrue(settings.containerInference)
        XCTAssertFalse(settings.record)
    }

    /// `--set` は基底の上に当たる(profile-less でも `--set heal=true` が効く)
    func testSetOverrideAppliesOnTopOfTheProfileLessBase() {
        let settings = DeviceIndependentRunSettings.resolve(
            DeviceIndependentRunSettings.profileLessBase.applyingOverrides(["heal": true]))
        XCTAssertTrue(settings.fm.heal, "--set heal=true は基底を上書きするはず")
        XCTAssertFalse(settings.fm.falsePositiveCheck, "触っていない欄は基底のまま")
    }


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
        // スカラー4欄は「未指定ならこの構造体では既定へ倒さない」契約(呼び出し側が既定を持つ)
        XCTAssertNil(settings.reportDir)
        XCTAssertNil(settings.defaultTimeout)
        XCTAssertNil(settings.scenarioTimeout)
        XCTAssertNil(settings.recordBitrateKbps)
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

    /// スカラー4欄(reportDir/defaultTimeout/scenarioTimeout/recordBitrateKbps)も同じ経路で
    /// profile-less まで届く(`fleetest run`/`fleetest api run` の profile-less パスが
    /// これらの値を読む唯一の場所。読み忘れると `--set` が黙って無視される)
    func testScalarOverridesFlowThroughResolve() {
        let doc = RunProfileDocument().applyingOverrides([
            "reportDir": .string("/tmp/custom"), "defaultTimeout": .double(9.5),
            "scenarioTimeout": .int(30), "recordBitrateKbps": .int(4000),
        ])
        let settings = DeviceIndependentRunSettings.resolve(doc)
        XCTAssertEqual(settings.reportDir, "/tmp/custom")
        XCTAssertEqual(settings.defaultTimeout, 9.5)
        XCTAssertEqual(settings.scenarioTimeout, 30)
        XCTAssertEqual(settings.recordBitrateKbps, 4000)
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

/// `RunProfileDocument.effectiveRecordBitrateKbps` は ProfileResolver.resolve(--profile あり)と
/// profile-less の録画構成(Fleetest.swift)が同じ既定を共有する唯一の定義元
final class EffectiveRecordBitrateKbpsTests: XCTestCase {
    func testNilFallsBackToTheDefault() {
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(nil),
                       VideoRecordingConfig.defaultBitrateKbps)
    }

    func testZeroOrNegativeFallsBackToTheDefault() {
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(0),
                       VideoRecordingConfig.defaultBitrateKbps)
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(-100),
                       VideoRecordingConfig.defaultBitrateKbps)
    }

    func testPositiveValuePassesThrough() {
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(4000), 4000)
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

    /// スカラーの `--set`(reportDir/defaultTimeout/scenarioTimeout/recordBitrateKbps)は
    /// runDoc から直接読まれる(ProfileResolver.resolve 参照。DeviceIndependentRunSettings を
    /// 経由しない4欄なので別に固定する)
    func testSetOverrideAppliesToScalarKeysWithAProfile() throws {
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m",
            overrides: [
                "reportDir": .string("/tmp/custom-report"), "defaultTimeout": .double(9.5),
                "scenarioTimeout": .int(30), "recordBitrateKbps": .int(4000),
            ])
        XCTAssertEqual(resolved.reportDir.path, "/tmp/custom-report")
        XCTAssertEqual(resolved.defaultTimeout, 9.5)
        XCTAssertEqual(resolved.scenarioTimeout, 30)
        XCTAssertEqual(resolved.recordBitrateKbps, 4000)
    }

    /// `--profile` が要るスカラーキー(app/machine/locale/wipeDataThresholdGB)も、
    /// --profile がある経路では devices に依存する他のキーと同じ関数を通って反映される
    func testSetOverrideAppliesToProfileOnlyScalarKeysWithAProfile() throws {
        let resolved = try ProfileResolver.resolve(
            project: project, runName: "r", machineName: "m",
            overrides: ["locale": .string("en_US"), "wipeDataThresholdGB": .double(4)])
        XCTAssertEqual(resolved.locale, "en_US")
        XCTAssertEqual(resolved.wipeDataThresholdGB, 4)
    }
}
