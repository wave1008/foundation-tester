import FTTestSupport
import XCTest
@testable import FTCore

/// この種のテストが finish() へ渡す fmSettings は値そのものを検査しないので固定の1値でよい
private let testFMSettings = FMSettingsRecord(
    fm: true, heal: false, falsePositiveCheck: false, screenLooksLike: true, triage: true,
    ocr: true, ocrFalsePositiveCheck: true)

final class RunRecordTests: XCTestCase {

    // MARK: - FM の死活(run.json の fmDead / fmDeadReason)

    /// 台帳(FMLiveness)へ死を注入して run.json を作らせる。**緑の run では1度も通らない経路**
    /// なので、フルスイートを何度回してもここは守られない(2026-09-03 の実 run で形を確認した)。
    /// FT_FM_LIVENESS_DIR はプロセス全体の状態なので SharedResource.hostCaches で直列化する。
    /// **FMBreaker もホスト単位の実ファイル**(`~/Library/Caches/fleetest/fm-breaker.state`)を持つ
    /// —— この実機で FM が実際に落ちていることがある(件1 の発端そのもの)ので、隔離しないと
    /// production の状態を拾って breakerOpen=false の期待が揺れる。既定で「閉じている」に固定する
    private func recordedMeta(injecting record: FMLiveness.Record?,
                              breakerOpen: Bool = false) throws -> RunMetaRecord {
        let ledgerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-fmdead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ledgerDir) }
        let saved = ProcessInfo.processInfo.environment["FT_FM_LIVENESS_DIR"]
        setenv("FT_FM_LIVENESS_DIR", ledgerDir.path, 1)
        defer { if let saved { setenv("FT_FM_LIVENESS_DIR", saved, 1) } else { unsetenv("FT_FM_LIVENESS_DIR") } }
        if let record {
            try JSONEncoder().encode(record).write(to: ledgerDir.appendingPathComponent("fm-liveness.json"))
        }

        let breakerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-fmbreaker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: breakerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: breakerDir) }
        let savedBreakerURL = FMBreaker.stateURLForTesting
        FMBreaker.stateURLForTesting = breakerDir.appendingPathComponent("fm-breaker.state")
        defer { FMBreaker.stateURLForTesting = savedBreakerURL }
        FMBreaker.reset()
        if breakerOpen {
            for _ in 0..<FMBreaker.threshold { FMBreaker.recordFailure() }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runrecord-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root),
                                         profile: "ios-fpc", trigger: "cli",
                                         captureHostMetrics: false)
        recorder.finish(total: 1, passed: 1, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        return try JSONDecoder().decode(
            RunMetaRecord.self,
            from: Data(contentsOf: recorder.runDir.appendingPathComponent("run.json")))
    }

    private func verdict(_ state: FMLiveness.State, _ error: String?) -> FMLiveness.Verdict {
        FMLiveness.Verdict(state: state, checkedAt: Date().timeIntervalSince1970,
                           source: .probe, error: error)
    }

    /// **緑の run にも印が残る**。合否は変えないが、FM が死んだ run の緑は occlusion-guard・
    /// 自己修復・screenLooksLike が素通りしただけかもしれない —— 後から仕分けるための欄
    func testDeadFMIsRecordedOnAPassingRun() throws {
        try SharedResource.hostCaches.locked {
            let meta = try recordedMeta(injecting: FMLiveness.Record(
                text: verdict(.alive, nil), vision: verdict(.dead, "ModelManagerError(1001)")))
            XCTAssertEqual(meta.passed, 1, "合否は変えない")
            XCTAssertEqual(meta.fmDead, ["vision"], "死んだ経路だけを名指しする")
            XCTAssertEqual(meta.fmDeadReason, "vision: ModelManagerError(1001)")
        }
    }

    /// 生きている run には欄を書かない(既存レコードと同じ形を保つ)。
    /// **欄が無い = 生きていた、ではない**ことは docs/results-json.md が持つ契約
    func testAliveFMLeavesTheFieldsOut() throws {
        try SharedResource.hostCaches.locked {
            let meta = try recordedMeta(injecting: FMLiveness.Record(
                text: verdict(.alive, nil), vision: verdict(.alive, nil)))
            XCTAssertNil(meta.fmDead)
            XCTAssertNil(meta.fmDeadReason)
        }
    }

    /// **観測が1件も無い(不明)を「死」と書かない**。台帳が無い機械の run すべてに
    /// 「FM は死んでいた」と印を付けると、仕分けの欄として使えなくなる
    func testUnknownLivenessIsNotRecordedAsDead() throws {
        try SharedResource.hostCaches.locked {
            let meta = try recordedMeta(injecting: nil)
            XCTAssertNil(meta.fmDead)
            XCTAssertNil(meta.fmDeadReason)
        }
    }

    /// 件1: 台帳の観測が無く(不明)、かつサーキットブレーカが開いていれば dead として補う。
    /// ブレーカは経路を区別しないので両方とも dead になる —— 「呼べば失敗する」が両経路に等しく効くため
    func testUnknownLivenessWithOpenBreakerIsRecordedAsDead() throws {
        try SharedResource.hostCaches.locked {
            let meta = try recordedMeta(injecting: nil, breakerOpen: true)
            XCTAssertEqual(meta.fmDead, ["text", "vision"])
            XCTAssertEqual(meta.fmDeadReason, "text: circuit breaker open / vision: circuit breaker open")
        }
    }

    /// **観測済みの経路は上書きしない**(新しい観測が勝つ規律)。text は台帳の生きた観測が
    /// あるので、ブレーカが開いていても text を dead にしない —— vision だけ不明のぶんを補う
    func testOpenBreakerDoesNotOverrideAFreshKnownReading() throws {
        try SharedResource.hostCaches.locked {
            let meta = try recordedMeta(
                injecting: FMLiveness.Record(text: verdict(.alive, nil), vision: nil),
                breakerOpen: true)
            XCTAssertEqual(meta.fmDead, ["vision"], "観測済みの text は上書きしない")
            XCTAssertEqual(meta.fmDeadReason, "vision: circuit breaker open")
        }
    }

    /// ブレーカが閉じていれば、不明はこれまでどおり不明のまま(欄を省略する)。
    /// 件1 の直しがこの規律まで壊していないことの対照
    func testUnknownLivenessWithClosedBreakerStaysOmitted() throws {
        try SharedResource.hostCaches.locked {
            let meta = try recordedMeta(injecting: nil, breakerOpen: false)
            XCTAssertNil(meta.fmDead)
            XCTAssertNil(meta.fmDeadReason)
        }
    }

    private func stepEvent(index: Int, scene: Int, status: String, description: String = "tap",
                           detail: String? = nil, file: String? = nil, line: Int? = nil,
                           durationMs: Int? = nil, snapshotMs: Int? = nil, actionMs: Int? = nil,
                           waitMs: Int? = nil, at: String? = nil,
                           notes: [String]? = nil, guarded: Bool? = nil) -> ScenarioEvent {
        var event = ScenarioEvent(kind: "step")
        event.index = index
        event.scene = scene
        event.status = status
        event.description = description
        event.detail = detail
        event.file = file
        event.line = line
        event.durationMs = durationMs
        event.snapshotMs = snapshotMs
        event.actionMs = actionMs
        event.waitMs = waitMs
        event.at = at
        event.notes = notes
        event.guarded = guarded
        return event
    }

    /// `runGroup`(束ね鍵)は **begin と finish の両方**で同じ値を書く —— finish で落とすと、
    /// 途中で落ちた run だけが束から外れて「マシンが1台足りない実行」に見える。
    /// 読み手は docs/results-json.md の runGroup。
    func testRecorderKeepsTheRunGroupFromBeginToFinish() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runrecord-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = TestProject(name: "P", rootURL: root)

        let recorder = RunRecorder.begin(project: project, profile: "android", trigger: "cli",
                                         captureHostMetrics: false,
                                         runGroup: "20260826-0100Z-LDIPC96-abcd")
        let metaURL = recorder.runDir.appendingPathComponent("run.json")
        func read() throws -> RunMetaRecord {
            try JSONDecoder().decode(RunMetaRecord.self, from: Data(contentsOf: metaURL))
        }
        XCTAssertEqual(try read().runGroup, "20260826-0100Z-LDIPC96-abcd")

        recorder.finish(total: 0, passed: 0, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        XCTAssertEqual(try read().runGroup, "20260826-0100Z-LDIPC96-abcd", "finish で欄が落ちてはいけない")
    }

    /// 単機の run(束ねる相手が居ない)では鍵を持たない
    func testRecorderOmitsTheRunGroupWhenNotGiven() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runrecord-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root),
                                         profile: nil, trigger: "cli", captureHostMetrics: false)
        let meta = try JSONDecoder().decode(
            RunMetaRecord.self,
            from: Data(contentsOf: recorder.runDir.appendingPathComponent("run.json")))
        XCTAssertNil(meta.runGroup)
    }

    // MARK: - fmSettings(実効 FM 設定)

    /// **7つとも常に明示的に書く**(true/false のどちらも省略しない)。JSONSerialization で
    /// 生の鍵の集合を数えることで、将来 encodeIfPresent 化されて false 値の欄が落ちる退行を
    /// (JSONDecoder 経由の丸め込みではなく)ここで検出する
    func testFmSettingsWritesAllSevenKeysExplicitlyIncludingFalseValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runrecord-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root),
                                         profile: "p", trigger: "cli", captureHostMetrics: false)
        let settings = FMSettingsRecord(
            fm: true, heal: false, falsePositiveCheck: true, screenLooksLike: false,
            triage: true, ocr: false, ocrFalsePositiveCheck: true)
        recorder.finish(total: 1, passed: 1, failed: 0, performanceMode: false, fmSettings: settings, setOverrides: nil)

        let data = try Data(contentsOf: recorder.runDir.appendingPathComponent("run.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fmSettingsJSON = try XCTUnwrap(json["fmSettings"] as? [String: Any])
        XCTAssertEqual(fmSettingsJSON.count, 7, "7つの欄すべてが書かれること(欠落は退行): \(fmSettingsJSON)")
        XCTAssertEqual(fmSettingsJSON["fm"] as? Bool, true)
        XCTAssertEqual(fmSettingsJSON["heal"] as? Bool, false)
        XCTAssertEqual(fmSettingsJSON["falsePositiveCheck"] as? Bool, true)
        XCTAssertEqual(fmSettingsJSON["screenLooksLike"] as? Bool, false)
        XCTAssertEqual(fmSettingsJSON["triage"] as? Bool, true)
        XCTAssertEqual(fmSettingsJSON["ocr"] as? Bool, false)
        XCTAssertEqual(fmSettingsJSON["ocrFalsePositiveCheck"] as? Bool, true)

        let meta = try JSONDecoder().decode(RunMetaRecord.self, from: data)
        XCTAssertEqual(meta.fmSettings, settings, "型付きの往復でも同じ値が読める")
    }

    /// 旧レコード(この版より前。fmSettings キーが無い)も decode できる。**欄が無い = FM が
    /// 無効だった意味ではない** —— 古い記録であることを表すだけ(docs/results-json.md)
    func testRunMetaRecordDecodesOldJsonWithoutFmSettingsKey() throws {
        let raw = "{\"schemaVersion\":1,\"runID\":\"x\",\"project\":\"SampleApp\",\"host\":\"m\","
            + "\"trigger\":\"cli\",\"startedAt\":\"2026-01-01T00:00:00Z\"}"
        let decoded = try XCTUnwrap(try? JSONDecoder().decode(RunMetaRecord.self, from: Data(raw.utf8)))
        XCTAssertNil(decoded.fmSettings)
    }

    func testFailedScenarioCollectsStepsScenesAndFailures() throws {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.bar", platform: "ios", title: "Foo bar", worker: "ios:iPhone 16")

        var started = ScenarioEvent(kind: "sceneStarted")
        started.scene = 1
        started.sceneTitle = "Scene A"
        builder.consume(started)

        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", durationMs: 100))
        builder.consume(stepEvent(
            index: 1, scene: 1, status: "failed", description: "exist #foo",
            detail: "見つかりません", file: "Scenario.swift", line: 42, durationMs: 50))

        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = false
        sceneFinished.durationMs = 250
        builder.consume(sceneFinished)

        var fix = ScenarioEvent(kind: "fixSuggestion")
        fix.scene = 1
        fix.file = "Scenario.swift"
        fix.line = 42
        fix.oldSelector = "#foo"
        fix.newSelector = "#foo2"
        builder.consume(fix)

        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.passed = false
        finished.reportPath = "/repo/root/TestProjects/SampleApp/reports/foo.json"
        builder.consume(finished)

        let record = builder.build(
            passed: false, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 900, packageRoot: URL(fileURLWithPath: "/repo/root"))

        XCTAssertEqual(record.scenarioID, "Foo.bar")
        XCTAssertEqual(record.platform, "ios")
        XCTAssertEqual(record.worker, "ios:iPhone 16")
        XCTAssertFalse(record.passed)
        XCTAssertEqual(record.durationMs, 900)

        XCTAssertEqual(record.scenes.count, 1)
        XCTAssertEqual(record.scenes[0].scene, 1)
        XCTAssertEqual(record.scenes[0].title, "Scene A")
        XCTAssertFalse(record.scenes[0].passed)
        XCTAssertEqual(record.scenes[0].durationMs, 250, "sceneFinished の durationMs を優先")

        XCTAssertEqual(record.steps.total, 2)
        XCTAssertEqual(record.steps.passed, 1)
        XCTAssertEqual(record.steps.failed, 1)

        let failedSteps = try XCTUnwrap(record.failedSteps)
        XCTAssertEqual(failedSteps.count, 1)
        XCTAssertEqual(failedSteps[0].index, 1)
        XCTAssertEqual(failedSteps[0].scene, 1)
        XCTAssertEqual(failedSteps[0].sceneTitle, "Scene A")
        XCTAssertEqual(failedSteps[0].description, "exist #foo")
        XCTAssertEqual(failedSteps[0].detail, "見つかりません")
        XCTAssertEqual(failedSteps[0].file, "Scenario.swift")
        XCTAssertEqual(failedSteps[0].line, 42)

        let fixSuggestions = try XCTUnwrap(record.fixSuggestions)
        XCTAssertEqual(fixSuggestions.count, 1)
        XCTAssertEqual(fixSuggestions[0].oldSelector, "#foo")
        XCTAssertEqual(fixSuggestions[0].newSelector, "#foo2")

        XCTAssertEqual(record.reportPath, "TestProjects/SampleApp/reports/foo.json", "packageRoot の prefix を剥がして相対化")
    }

    func testPassedScenarioHasNilFailureFields() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.baz", platform: "android", title: nil, worker: nil)

        var started = ScenarioEvent(kind: "sceneStarted")
        started.scene = 1
        started.sceneTitle = "Scene A"
        builder.consume(started)
        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", durationMs: 10))

        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = true
        builder.consume(sceneFinished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 50, packageRoot: nil)

        XCTAssertTrue(record.passed)
        XCTAssertNil(record.failedSteps)
        XCTAssertNil(record.fixSuggestions, "提案イベントが1つも来ていないので nil(成否とは無関係)")
        XCTAssertEqual(record.scenes[0].durationMs, 10, "sceneFinished に durationMs が無ければ step 合計を使う")
    }

    /// **修正提案は成否によらず残す**。強い提案が出るのは自己修復かヒールキャッシュで
    /// **通ったとき**なので、passed で捨てると「緑だがセレクタは壊れている」という
    /// 一番知りたい状態の記録が1件も残らない(実測: 89,025 記録すべてで空だった)
    func testPassedScenarioKeepsItsFixSuggestions() throws {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.heal", platform: "ios", title: nil, worker: nil)
        builder.consume(stepEvent(index: 0, scene: 1, status: "healed", durationMs: 10))
        var suggestion = ScenarioEvent(kind: "fixSuggestion")
        suggestion.scene = 1
        suggestion.file = "Scenarios/Foo.swift"
        suggestion.line = 12
        suggestion.oldSelector = "#old_id"
        suggestion.newSelector = "#new_id"
        builder.consume(suggestion)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 50, packageRoot: nil)

        XCTAssertTrue(record.passed)
        let suggestions = try XCTUnwrap(record.fixSuggestions)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.oldSelector, "#old_id")
        XCTAssertEqual(suggestions.first?.newSelector, "#new_id")
    }

    func testReportPathKeptAsIsWhenPrefixMismatches() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.qux", platform: "ios", title: nil, worker: nil)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.reportPath = "/elsewhere/reports/foo.json"
        builder.consume(finished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: URL(fileURLWithPath: "/repo/root"))

        XCTAssertEqual(record.reportPath, "/elsewhere/reports/foo.json")
    }

    func testFailedStepCarriesAtFromScenarioEvent() throws {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.at", platform: "ios", title: nil, worker: nil)
        builder.consume(stepEvent(index: 0, scene: 1, status: "failed", description: "exist #foo",
                                  detail: "見つかりません", at: "2026-07-23T12:34:56.789Z"))

        let record = builder.build(
            passed: false, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 10, packageRoot: nil)

        let failedSteps = try XCTUnwrap(record.failedSteps)
        XCTAssertEqual(failedSteps[0].at, "2026-07-23T12:34:56.789Z")
    }

    func testTimelineCollectsAllStepsInArrivalOrderRegardlessOfStatus() throws {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.timeline", platform: "ios", title: nil, worker: nil)

        var started = ScenarioEvent(kind: "sceneStarted")
        started.scene = 1
        started.sceneTitle = "ログインできる"
        builder.consume(started)

        builder.consume(stepEvent(index: 1, scene: 1, status: "passed", description: "launchApp()",
                                  durationMs: 200, at: "2026-07-23T15:55:33.000Z"))
        builder.consume(stepEvent(index: 2, scene: 1, status: "skipped", description: "tap \"#optional\"",
                                  durationMs: nil, at: nil))
        builder.consume(stepEvent(index: 3, scene: 1, status: "failed", description: "tap \"#btn\"",
                                  detail: "見つかりません", durationMs: 1300,
                                  at: "2026-07-23T15:55:34.642Z"))

        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = false
        builder.consume(sceneFinished)

        let record = builder.build(
            passed: false, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 1500, packageRoot: nil)

        let timeline = try XCTUnwrap(record.timeline)
        XCTAssertEqual(timeline.count, 3, "passed/skipped/failed すべて収集されるはず")

        XCTAssertEqual(timeline[0].index, 1)
        XCTAssertEqual(timeline[0].status, "passed")
        XCTAssertEqual(timeline[0].description, "launchApp()")
        XCTAssertEqual(timeline[0].scene, 1)
        XCTAssertEqual(timeline[0].sceneTitle, "ログインできる", "sceneTitle 未指定時は sceneStarted 由来を解決")
        XCTAssertEqual(timeline[0].durationMs, 200)
        XCTAssertEqual(timeline[0].at, "2026-07-23T15:55:33.000Z")

        XCTAssertEqual(timeline[1].index, 2)
        XCTAssertEqual(timeline[1].status, "skipped")
        XCTAssertNil(timeline[1].durationMs)
        XCTAssertNil(timeline[1].at, "at 未指定のステップは nil のまま")

        XCTAssertEqual(timeline[2].index, 3)
        XCTAssertEqual(timeline[2].status, "failed")
        XCTAssertEqual(timeline[2].description, "tap \"#btn\"")
        XCTAssertEqual(timeline[2].durationMs, 1300)
        XCTAssertEqual(timeline[2].at, "2026-07-23T15:55:34.642Z")
    }

    func testTimelineNilWhenNoSteps() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.notimeline", platform: "ios", title: nil, worker: nil)
        var finished = ScenarioEvent(kind: "scenarioFinished")
        finished.passed = true
        builder.consume(finished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertNil(record.timeline)
    }

    /// 件2: durationMs の内訳(snapshotMs/actionMs/waitMs)は計測できたステップだけ載り、
    /// 未計測のステップと欄そのものが無い旧レコードはキーごと省略される(0 と混ぜない)
    func testTimelineCarriesDurationBreakdownWhenMeasured() throws {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.breakdown", platform: "ios", title: nil, worker: nil)

        builder.consume(stepEvent(index: 1, scene: 1, status: "passed", description: "tap \"#btn\"",
                                  durationMs: 104_000, snapshotMs: 90_000, actionMs: 12_000, waitMs: 2_000))
        builder.consume(stepEvent(index: 2, scene: 1, status: "passed", description: "wait(1)",
                                  durationMs: 1000))

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 105_000, packageRoot: nil)

        let timeline = try XCTUnwrap(record.timeline)
        XCTAssertEqual(timeline[0].snapshotMs, 90_000)
        XCTAssertEqual(timeline[0].actionMs, 12_000)
        XCTAssertEqual(timeline[0].waitMs, 2_000)
        XCTAssertNil(timeline[1].snapshotMs, "未計測のステップはキーごと省略(0 ではない)")
        XCTAssertNil(timeline[1].actionMs)
        XCTAssertNil(timeline[1].waitMs)

        // JSON へ落としたときも欄ごと消えること(synthesized Codable が Optional を
        // encodeIfPresent で書く契約。手で キー集合を確かめる)
        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let jsonTimeline = try XCTUnwrap(json["timeline"] as? [[String: Any]])
        XCTAssertEqual(jsonTimeline[0]["snapshotMs"] as? Int, 90_000)
        XCTAssertNil(jsonTimeline[1]["snapshotMs"], "nil の欄はキーごと出ないこと")
        XCTAssertNil(jsonTimeline[1]["actionMs"])
        XCTAssertNil(jsonTimeline[1]["waitMs"])
    }

    /// inconclusive(verify にアサーション0個等)は failed に数えず、専用カウンタへ積む
    func testInconclusiveStepsAreCountedSeparatelyFromFailures() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.inconclusive", platform: "ios", title: nil, worker: nil)

        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", durationMs: 10))
        builder.consume(stepEvent(index: 1, scene: 1, status: "inconclusive",
                                  description: "verify \"何か\"",
                                  detail: "verify block contains no assertions", durationMs: 5))

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 15, packageRoot: nil)

        XCTAssertEqual(record.steps.total, 2)
        XCTAssertEqual(record.steps.passed, 1)
        XCTAssertEqual(record.steps.failed, 0, "inconclusive は failed に数えないこと")
        XCTAssertEqual(record.steps.inconclusive, 1)
        XCTAssertNil(record.failedSteps, "inconclusive は failedSteps に載らないこと")

        let timeline = try? XCTUnwrap(record.timeline)
        XCTAssertEqual(timeline?[1].status, "inconclusive")
    }

    // MARK: - occlusion-guard(誤った緑の検査)がどれだけ効いたか

    /// **分母は event.guarded==true の回数**であって、ガード対象になり得たステップの数
    /// (visibilityGuardActive)ではない。tap 等のアクションは guarded を立てない(false/nil)ので
    /// 数に入らないことを確かめる
    func testGuardedCountsOnlyStepsThatEnteredOcclusionFlip() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.guard", platform: "ios", title: nil, worker: nil)
        // exist が occlusionFlip に入り可視と判定された(素通りではない)ケース
        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", guarded: true))
        // tap 等のアクションは occlusionFlip を通らない = guarded は立たない
        builder.consume(stepEvent(index: 1, scene: 1, status: "passed", guarded: false))
        // visibilityGuardActive が false(ガード無効)で occlusionFlip の入口で降りた
        builder.consume(stepEvent(index: 2, scene: 1, status: "passed", guarded: nil))

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertEqual(record.steps.guarded, 1, "guarded==true のステップだけを数える")
        // ガードに入っている以上、素通りが0件だったことは**観測された事実**なので0を書く
        // (欄を落とすと「ガードに入っていない」と区別が付かない。run 合計と同じ規律)
        XCTAssertEqual(record.steps.guardSkipped, 0, "入ったが素通りは起きなかった = 0")
        XCTAssertEqual(record.steps.guardStaleFrame, 0)
    }

    /// ガードに1度も入らなかったシナリオでは3欄とも省く(0 を書かない) ——
    /// 「観測なし」と「観測したが0件」を記録の階層をまたいで混ぜないため
    func testGuardFieldsAreOmittedEntirelyWhenTheGuardNeverRan() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.noguard", platform: "ios", title: nil, worker: nil)
        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", guarded: false))
        builder.consume(stepEvent(index: 1, scene: 1, status: "passed", guarded: nil))

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertNil(record.steps.guarded)
        XCTAssertNil(record.steps.guardSkipped)
        XCTAssertNil(record.steps.guardStaleFrame)
    }

    /// guarded に入った回のうち、`visibility-guard-skipped` / `stale-screenshot` の注記が付いた回を
    /// それぞれ別カウンタへ積む(FM が判定を返せなかった/絵が古かった=素通りの内訳)
    func testGuardSkippedAndStaleFrameAreCountedFromNotes() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.guardskip", platform: "ios", title: nil, worker: nil)
        builder.consume(stepEvent(index: 0, scene: 1, status: "passed", guarded: true))
        builder.consume(stepEvent(index: 1, scene: 1, status: "passed",
                                  notes: [StepNote.visibilityGuardSkipped.rawValue], guarded: true))
        builder.consume(stepEvent(index: 2, scene: 1, status: "passed",
                                  notes: [StepNote.staleScreenshot.rawValue], guarded: true))

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertEqual(record.steps.guarded, 3)
        XCTAssertEqual(record.steps.guardSkipped, 1)
        XCTAssertEqual(record.steps.guardStaleFrame, 1)
    }

    /// ガードが1度も走らなかったシナリオでは3欄とも nil のまま(0を書かない)
    func testGuardCountsAreNilWhenGuardNeverRan() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.noguard", platform: "ios", title: nil, worker: nil)
        builder.consume(stepEvent(index: 0, scene: 1, status: "passed"))

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertNil(record.steps.guarded)
        XCTAssertNil(record.steps.guardSkipped)
        XCTAssertNil(record.steps.guardStaleFrame)
    }

    // MARK: - RunRecorder: run 合計への集計と 0/nil の使い分け

    private func runRecorder() throws -> (recorder: RunRecorder, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-runrecord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RunRecorder.begin(project: TestProject(name: "P", rootURL: root),
                                         profile: nil, trigger: "cli", captureHostMetrics: false)
        return (recorder, { try? FileManager.default.removeItem(at: root) })
    }

    private func readMeta(_ recorder: RunRecorder) throws -> RunMetaRecord {
        try JSONDecoder().decode(
            RunMetaRecord.self,
            from: Data(contentsOf: recorder.runDir.appendingPathComponent("run.json")))
    }

    /// 1度もガードに入らなかった run(全シナリオが guarded==nil)では、run.json にも3欄とも
    /// 書かない(欠落キー=観測なし、を保つ)
    func testRunTotalsOmitGuardFieldsWhenNoScenarioEnteredTheGuard() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.a", platform: "ios", passed: true,
            startedAt: "2026-09-07T00:00:00.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 1, passed: 1)))

        recorder.finish(total: 1, passed: 1, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertNil(meta.guarded)
        XCTAssertNil(meta.guardSkipped)
        XCTAssertNil(meta.guardStaleFrame)
    }

    /// guarded が1件以上ある run では、guardSkipped/guardStaleFrame が0件でも**明示的に0を書く**
    /// (欄が無い=観測なし、0=観測したが起きなかった、を混ぜない。CLAUDE.md の規律)
    func testRunTotalsWriteExplicitZeroWhenGuardRanButNeverSkipped() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.b", platform: "ios", passed: true,
            startedAt: "2026-09-07T00:00:00.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 1, passed: 1, guarded: 3)))

        recorder.finish(total: 1, passed: 1, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertEqual(meta.guarded, 3)
        XCTAssertEqual(meta.guardSkipped, 0, "0件でも欄が無くなってはいけない")
        XCTAssertEqual(meta.guardStaleFrame, 0)
    }

    /// 複数シナリオの guarded/guardSkipped/guardStaleFrame は run 合計に単純加算される
    func testRunTotalsSumAcrossScenarios() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.c1", platform: "ios", passed: true,
            startedAt: "2026-09-07T00:00:00.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 2, passed: 2, guarded: 2, guardSkipped: 1,
                                    guardStaleFrame: 0)))
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.c2", platform: "ios", passed: true,
            startedAt: "2026-09-07T00:00:00.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 1, passed: 1, guarded: 1, guardSkipped: 0,
                                    guardStaleFrame: 1)))

        recorder.finish(total: 2, passed: 2, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertEqual(meta.guarded, 3)
        XCTAssertEqual(meta.guardSkipped, 1)
        XCTAssertEqual(meta.guardStaleFrame, 1)
    }

    /// 凍結・環境エラーの再実行で `discardLast` が直前の記録を取り消したら、その記録の
    /// ガード計数も run 合計から引く。引かないと同じシナリオを2回数え、**保護できた割合が
    /// 実際より高く見える**(この記録を足した目的そのものを損なう)
    func testDiscardedRecordIsRemovedFromGuardTotals() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        // 1回目(凍結して捨てられる回)
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.retry", platform: "ios", passed: false,
            startedAt: "2026-09-07T00:00:00.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 5, passed: 5, guarded: 5, guardSkipped: 4,
                                    guardStaleFrame: 1)))
        recorder.discardLast(scenarioID: "Foo.retry")
        // 再実行(こちらだけが残る)
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.retry", platform: "ios", passed: true,
            startedAt: "2026-09-07T00:00:10.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 2, passed: 2, guarded: 2, guardSkipped: 0,
                                    guardStaleFrame: 0)))

        recorder.finish(total: 1, passed: 1, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertEqual(meta.guarded, 2, "捨てた回の 5 を足したままにしない")
        XCTAssertEqual(meta.guardSkipped, 0, "捨てた回の 4 を足したままにしない")
        XCTAssertEqual(meta.guardStaleFrame, 0)
    }

    /// 取り消しで合計が 0 に戻ったら3欄とも書かない(「ガードが1度も走らなかった run」と同じ形)
    func testDiscardingTheOnlyGuardedRecordOmitsTheFields() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.record(ScenarioRunRecord(
            scenarioID: "Foo.only", platform: "ios", passed: false,
            startedAt: "2026-09-07T00:00:00.000Z", durationMs: 10,
            steps: StepCountsRecord(total: 3, passed: 3, guarded: 3, guardSkipped: 2,
                                    guardStaleFrame: 1)))
        recorder.discardLast(scenarioID: "Foo.only")

        recorder.finish(total: 0, passed: 0, failed: 0, performanceMode: false, fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertNil(meta.guarded)
        XCTAssertNil(meta.guardSkipped)
        XCTAssertNil(meta.guardStaleFrame)
    }

    // MARK: - run.json は `--set` の上書きを記録する

    /// 戻すと落ちる根拠: revert すると setOverrides を渡していない run.json でも
    /// キーが読めてしまう(実際には無かった上書きが記録に「ある」ことになる)
    func testFinishOmitsSetOverridesWhenNoneGiven() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.finish(total: 0, passed: 0, failed: 0, performanceMode: false,
                        fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertNil(meta.setOverrides)
    }

    /// 戻すと落ちる根拠: revert すると `--set scenarioTimeout=3` 等の上書きが run.json から
    /// 消え、insights が打ち切り run を通常の失敗と区別できなくなる(打ち切り run を区別できない実害の再現条件)
    func testFinishRecordsSetOverridesWhenGiven() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.finish(total: 0, passed: 0, failed: 0, performanceMode: false,
                        fmSettings: testFMSettings,
                        setOverrides: ["scenarioTimeout": "3", "iosInappEngine": "false"])
        let meta = try readMeta(recorder)
        XCTAssertEqual(meta.setOverrides, ["scenarioTimeout": "3", "iosInappEngine": "false"])
    }

    /// 空辞書は「上書き無し」と区別する意味が無いので nil に畳む(記録上は同じ形に揃える)
    func testFinishOmitsSetOverridesWhenEmptyDictionaryGiven() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.finish(total: 0, passed: 0, failed: 0, performanceMode: false,
                        fmSettings: testFMSettings, setOverrides: [:])
        let meta = try readMeta(recorder)
        XCTAssertNil(meta.setOverrides)
    }

    // MARK: - run.json は中断・供給段の異常終了を finishedAt 付きで記録する
    // 

    /// 既定(interrupted 省略)では欄を書かない。**戻すと落ちる根拠**: revert して
    /// `interrupted` を常に false で書く実装にすると、この false が「事実」として
    /// 記録され、旧レコードと見分けがつかなくなる(欄の有無で「観測なし」と「false」を混ぜない規律)
    func testFinishOmitsInterruptedWhenNotGiven() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.finish(total: 1, passed: 0, failed: 1, performanceMode: false,
                        fmSettings: testFMSettings, setOverrides: nil)
        let meta = try readMeta(recorder)
        XCTAssertNil(meta.interrupted)
        XCTAssertNil(meta.abortReason)
    }

    /// 戻すと落ちる根拠: revert すると SIGINT/SIGTERM で打ち切られた run が
    /// 通常の失敗と見分けられなくなる(results insights の「クラッシュ」誤分類の直接の原因)
    func testFinishRecordsInterruptedWhenTrue() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.finish(total: 3, passed: 1, failed: 2, performanceMode: false,
                        fmSettings: testFMSettings, setOverrides: nil, interrupted: true)
        let meta = try readMeta(recorder)
        XCTAssertEqual(meta.interrupted, true)
        XCTAssertNotNil(meta.finishedAt, "中断でも finishedAt は必ず書く(F28)")
    }

    /// 戻すと落ちる根拠: revert すると供給段(ワーカー構築等)の例外で終わった run の
    /// finishedAt/abortReason が抜け、results insights が「クラッシュ」に数える
    func testFinishRecordsAbortReasonWhenGiven() throws {
        let (recorder, cleanup) = try runRecorder()
        defer { cleanup() }
        recorder.finish(total: 4, passed: 0, failed: 4, performanceMode: false,
                        fmSettings: testFMSettings, setOverrides: nil,
                        abortReason: "no usable devices (every Android device went blank)")
        let meta = try readMeta(recorder)
        XCTAssertEqual(meta.abortReason, "no usable devices (every Android device went blank)")
        XCTAssertNil(meta.interrupted, "abort は中断とは別の事実(混ぜない)")
        XCTAssertNotNil(meta.finishedAt)
    }

    func testSceneWithoutAnyDurationEventsIsNil() {
        var builder = ScenarioRecordBuilder(
            scenarioID: "Foo.quux", platform: "ios", title: nil, worker: nil)
        var sceneFinished = ScenarioEvent(kind: "sceneFinished")
        sceneFinished.scene = 1
        sceneFinished.passed = true
        builder.consume(sceneFinished)

        let record = builder.build(
            passed: true, timedOut: false, startedAt: Date(timeIntervalSince1970: 0),
            durationMs: 0, packageRoot: nil)

        XCTAssertNil(record.scenes[0].durationMs)
    }
}
