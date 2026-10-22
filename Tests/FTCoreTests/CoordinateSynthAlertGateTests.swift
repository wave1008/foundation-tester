// 直接合成(CoordinatePinch)は XCTest の割り込み監視を通らず、システムアラートのボタンを押してしまう。
// 送る口の synthesize の前に必ずゲートがあること、送る口が CoordinatePinch に閉じていることを固定する。

import XCTest

final class CoordinateSynthAlertGateTests: XCTestCase {

    private var runnerDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Runner/FleetestRunnerUITests")
    }

    func testEverySynthesizeCallIsPrecededByAlertGateInSameFunction() throws {
        let source = try String(contentsOf: runnerDir.appendingPathComponent("CoordinatePinch.swift"),
                                encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        var found = 0
        for (index, line) in lines.enumerated() where line.contains("synthesizer.synthesize(") {
            found += 1
            // 同じ関数 = 直前の `func ` 宣言行から
            var start = index
            while start > 0, !lines[start].contains(" func ") { start -= 1 }
            let before = lines[start..<index].joined(separator: "\n")
            XCTAssertTrue(before.contains("try refuseIfSystemAlertInFront()"),
                          "CoordinatePinch.swift:\(index + 1) の synthesize の前に refuseIfSystemAlertInFront() が無い")
        }
        XCTAssertGreaterThanOrEqual(found, 2, "走査が synthesize の呼び出しに届いていない(送る口は send と holdWithoutWaiting)")
    }

    /// SpringBoard を相手にした `/tap`(inapp モードがアラートのボタンを押す経路)は直接合成へ入れない。
    /// 入れると送る口の門がアラートのボタンそのものを断り、iosAlertHandler が押せずに期限まで空回りする
    func testMainScreenTapSkipsDirectSynthesisForSpringBoardSession() throws {
        let source = try String(contentsOf: runnerDir.appendingPathComponent("BridgeRouter.swift"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let callers = lines.indices.filter { lines[$0].contains("CoordinatePinch.tapOnMainScreen(") }
        XCTAssertEqual(callers.count, 1, "走査が主画面の tap の直接合成に届いていない")
        for index in callers {
            let guardLine = lines[index - 1]
            XCTAssertTrue(guardLine.contains("sessionBundleID != \"com.apple.springboard\""),
                          "BridgeRouter.swift:\(index) の直接合成の分岐が SpringBoard のセッションを除いていない: \(guardLine)")
        }
    }

    func testOnlyCoordinatePinchCallsSynthesizeInBridgeRouter() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: runnerDir.path)
            .filter { $0.hasPrefix("BridgeRouter") && $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("BridgeRouter.swift"), "走査が BridgeRouter.swift に届いていない")
        for name in names {
            let source = try String(contentsOf: runnerDir.appendingPathComponent(name), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                guard let range = code.range(of: "synthesize(") else { continue }
                XCTAssertTrue(code[..<range.lowerBound].hasSuffix("CoordinatePinch."),
                              "\(name):\(index + 1) が CoordinatePinch を介さず synthesize を呼んでいる(アラートのゲートを通らない)")
            }
        }
    }
}
