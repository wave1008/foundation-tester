// XCUITest ランナーの操作(タップ・スワイプ・ドラッグ・ピンチ・回転・打鍵・ホーム)は、XCTest の待ちを
// `QuiescenceWait.around` / `capping`(または `gestureQuiescence` / `tapBeforeTyping`)の中で撃つ。外で撃つと待ちの上限が縮まらず、
// 知らせを返さないアプリ(Apple マップ)で XCTest 既定の 60s 止まる(実測: シートを広げる /drag で 60s → ホストがランナーを起動し直した)。
// 走査は「操作の行を含む関数が、その行より前に包みを開いているか」を見る。呼び手が包む関数は表に載せ、呼び手の包みも確かめる

import XCTest

final class RunnerQuiescenceCapCoverageTests: XCTestCase {

    private static let interaction = try! NSRegularExpression(pattern:
        #"\.(tap|doubleTap)\(\)|\.press\(|\.pinch\(|\.swipe(Up|Down|Left|Right)\(|typeText\(|XCUIDevice\.shared\.(press\(|orientation *=)"#)
    private static let wrappers = ["gestureQuiescence {", "QuiescenceWait.around(", "QuiescenceWait.capping"]
    /// 呼び手が包みの中で呼ぶ関数 → その包みの印(呼び手のソースに現れるべき文字列)
    private static let wrappedByCaller: [String: String] = [
        "typeAndReadBack": "QuiescenceWait.capping(skipPostEvent: true) { try typeAndReadBack(body) }",
        "performTypeReadback": "QuiescenceWait.capping(skipPostEvent: true) { try typeAndReadBack(body) }",
        "clearFocusedInput": "QuiescenceWait.capping(skipPostEvent: false) { try clearFocusedInput(body) }",
        "sendHomeGesture": "gestureQuiescence { sendHomeGesture(sb) }",
    ]

    func testEveryRunnerInteractionRunsInsideAQuiescenceCap() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runner/FleetestRunnerUITests")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("BridgeRouter.swift"), "走査が Runner に届いていない")
        var all = ""
        var checked = 0
        var offenders: [String] = []
        for name in names {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            all += text
            var function = ""
            var wrapperSeen = false
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                // コメントと文字列リテラル(エラー文に API 名が出る)を落としてから見る
                let line = (raw.components(separatedBy: "//").first ?? raw)
                    .replacingOccurrences(of: #""(\\.|[^"\\])*""#, with: "\"\"", options: .regularExpression)
                if let range = line.range(of: #"func [A-Za-z]+"#, options: .regularExpression) {
                    function = String(line[range].dropFirst(5))
                    wrapperSeen = false
                }
                if Self.wrappers.contains(where: line.contains) { wrapperSeen = true }
                guard Self.interaction.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                else { continue }
                checked += 1
                if wrapperSeen || Self.wrappedByCaller[function] != nil { continue }
                offenders.append("\(name):\(i + 1) [\(function)] \(raw.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20, "走査が操作の呼び出しに届いていない")
        XCTAssertEqual(offenders, [], "XCTest の待ちの上限の外で操作を撃っている(60s 止まりうる)")
        for (function, mark) in Self.wrappedByCaller {
            XCTAssertTrue(all.contains(mark), "\(function) を包みの中で呼ぶ呼び手が見つからない: \(mark)")
        }
    }
}
