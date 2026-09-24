// 実機の「画面が暗い」観測が **run / api run の両経路**に配線されていることをソース走査で固定する。
//
// この砦が要る理由: iOS ワーカーの供給は `ProfileRunner.buildIOSLane` という別関数で、
// Android ワーカーはその手前で作られる。`api run` はワーカーが**混在リスト**なので
// `BlankWorkerTriage.excludeBlankScreenWorkers` 1本で両 OS を見ているが、`fleetest run` は
// iOS レーンの中でしか呼んでおらず、**Android 実機だけが無観測**だった(2026-09-25)。
// 同じ型の穴は `RunCommandFlagParityTests` が扱う「run と api run は別実装」の一族で、
// どちらの経路も緑のまま通るので実行では捕まらない。

import XCTest

final class PhysicalDarkScreenWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"),
                          encoding: .utf8)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var cursor = text.startIndex
        while let next = text.range(of: needle, range: cursor..<text.endIndex) {
            count += 1
            cursor = next.upperBound
        }
        return count
    }

    /// **本数を等号で固定する**。`contains` では駄目 —— どちらのファイルにも iOS 供給口の
    /// 呼び出しが別にあるので、**Android 実機ぶんを消しても文字列は残って通ってしまう**
    /// (この形で実際に変異が生き延びた)。
    ///   - ProfileRunner: Android ワーカーの観測が1本。iOS レーンは `excludeBlankScreenWorkers`
    ///     の側で見ているので、**観測専用の口はここだけ**
    ///   - ApiRunCommand: **ワーカーが混在リスト**なので既存の `excludeBlankScreenWorkers`
    ///     (iOS の供給口2つ)が実機も拾う = 観測専用の口は要らない
    func testBothRunPathsObservePhysicalScreens() throws {
        for file in ["ProfileRunner.swift", "ApiRunCommand.swift"] {
            XCTAssertEqual(occurrences(of: "BlankWorkerTriage.observePhysicalScreens",
                                       in: try source(file)), 1,
                           "\(file): 実機の観測を失っている")
        }
    }

    /// **材料と修復は両経路で同じものを渡す**。片方だけが渡すと、同じ端末について
    /// `fleetest run` と `fleetest api run` で別の判定が出る(どちらも緑のまま通る)
    func testBothRunPathsPassTheSameProbes() throws {
        for file in ["ProfileRunner.swift", "ApiRunCommand.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("PhysicalScreenProbes.awake"), "\(file): awake の材料")
            XCTAssertTrue(text.contains("PhysicalScreenProbes.cycleScreen"), "\(file): 修復")
        }
    }

    /// Android ワーカーを作る `ProfileRunner` 側は、**Android 側のトリアージの直後**に通すこと。
    /// あちらは実機を対象外にしているので、順序が逆だと実機が素通りする
    func testProfileRunnerObservesRightAfterTheAndroidTriage() throws {
        let text = try source("ProfileRunner.swift")
        guard let androidTriage = text.range(of: "excludeOrRepairBlankScreenWorkers"),
              let observation = text.range(of: "BlankWorkerTriage.observePhysicalScreens") else {
            return XCTFail("ProfileRunner に両方の呼び出しが要る")
        }
        XCTAssertTrue(androidTriage.upperBound < observation.lowerBound,
                      "観測は Android 側のトリアージ(実機は対象外)の後に置く")
        if let iosLane = text.range(of: "private static func buildIOSLane") {
            XCTAssertTrue(observation.lowerBound < iosLane.lowerBound,
                          "Android 側の観測が buildIOSLane の中へ紛れている")
        }
    }
}
