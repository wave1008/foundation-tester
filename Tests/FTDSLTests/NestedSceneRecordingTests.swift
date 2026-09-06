// 入れ子の `scene` を出た後のステップは**外側の scene**へ記録される。
// `record.scenes.last` で「今の scene」を決めると、`scene(1){ tap; scene(2){…}; exist }` の
// `exist` が scene 2 に落ち、scene 1 の合否(sceneFinished の passed)も scene 2 のものになる。

import XCTest
@testable import FTDSL
import FTCore

final class NestedSceneRecordingTests: XCTestCase {

    private final class StubDriver: AppDriver {
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws {}
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private func makeCore(emit: @escaping (ScenarioEvent) -> Void = { _ in }) -> FTDriveCore {
        FTDriveCore(driver: StubDriver(), platform: "ios", app: "com.example.app",
                    scenarioID: "T.S0010", scenarioTitle: "t",
                    delegate: nil, healingEnabled: false, dryRun: true,
                    healCacheURL: URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ft-nested-scene-test.json"),
                    emit: emit)
    }

    /// 本命: 内側を出た後のステップは外側に載る
    func test内側のsceneを出た後のステップは外側に記録される() {
        var stepScenes: [(scene: Int?, description: String)] = []
        let core = makeCore { event in
            if event.kind == "step" { stepScenes.append((event.scene, event.description ?? "")) }
        }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "outer") {
                tap("#a")
                scene(2, "inner") { tap("#b") }
                exist("#c")
            }
        }

        let scenes = core.finalRecord.scenes
        XCTAssertEqual(scenes.map(\.number), [1, 2])
        XCTAssertEqual(scenes[0].steps.map(\.description), ["tap \"#a\"", "exist \"#c\""],
                       "外側の scene に tap と exist が載る: \(scenes[0].steps.map(\.description))")
        XCTAssertEqual(scenes[1].steps.map(\.description), ["tap \"#b\""],
                       "内側の scene には内側のステップだけ: \(scenes[1].steps.map(\.description))")
        // step イベントの scene 番号も同じ(拡張が読む側)
        XCTAssertEqual(stepScenes.map(\.scene), [1, 2, 1], "\(stepScenes)")
    }

    /// sceneFinished の passed は**その scene**のもの。外側が内側の後で落ちても、
    /// 内側の sceneFinished(先に出る)は緑・外側は赤
    func testSceneFinishedの合否はそのsceneのもの() {
        var finished: [(scene: Int?, passed: Bool?)] = []
        let core = makeCore { event in
            if event.kind == "sceneFinished" { finished.append((event.scene, event.passed)) }
        }
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "outer") {
                scene(2, "inner") { tap("#b") }
                tap(".Button:near(合計)")   // 構文誤り = dry-run でも失敗する(外側に載る)
            }
        }

        XCTAssertEqual(finished.map(\.scene), [2, 1])
        XCTAssertEqual(finished.map(\.passed), [true, false],
                       "内側は緑・外側は赤にならない: \(finished)")
        let scenes = core.finalRecord.scenes
        XCTAssertTrue(scenes[1].passed)
        XCTAssertFalse(scenes[0].passed, "失敗ステップが外側に載っていない")
    }

    /// 従来の挙動を保つ: scene の外(scene が1つも無い)のステップは暗黙 scene 0 に載る
    func testSceneの外のステップは暗黙scene0に載る() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario { tap("#a") }

        let scenes = core.finalRecord.scenes
        XCTAssertEqual(scenes.map(\.number), [0])
        XCTAssertEqual(scenes[0].steps.count, 1)
    }

    /// 従来の挙動を保つ: scene を出た後(入れ子でない)のステップは直近の scene に載る
    /// (tearDown の記録がこの形。FTRuntimeLifecycleTests.testTearDownRunsAfterSceneFailure)
    func testSceneを出た後のステップは直近のsceneに載る() {
        let core = makeCore()
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }

        scenario {
            scene(1, "s") { action { tap("#a") } }
            tap("#after")
        }

        let scenes = core.finalRecord.scenes
        XCTAssertEqual(scenes.map(\.number), [1])
        XCTAssertEqual(scenes[0].steps.map(\.description), ["tap \"#a\"", "tap \"#after\""])
    }
}
