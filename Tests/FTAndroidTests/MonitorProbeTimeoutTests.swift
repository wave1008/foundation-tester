// `api monitor`(既定 2 秒周期)から呼ばれる adb は締切付きで撃つ。adbd が wedge すると
// `adb shell …` は無期限に返らず、モニターの1周ごと(= 全デバイスの状態・映像)が固まる。
// 締切が尽きると Shell は `ShellError.timedOut` を投げ、各呼び出し側の `try?` が「取得できない」
// (判定スキップ / false / nil)へ倒す ―― クラッシュにも誤検知にもならない。
//
// 走査で守る呼び出し(コマンド配列):
//   AndroidHealthProbe.swift
//     [adb, "-s", serial, "shell", "dumpsys", "SurfaceFlinger"]      detectRenderMode
//     [adb, "-s", serial, "shell", "cmd", "wifi", "status"]          observeIssues
//     [adb, "-s", serial, "shell", "date", "+%s"]                    observeIssues
//     [adb, "-s", serial, "shell", "input", "keyevent", "KEYCODE_SLEEP"]   repairBlankDisplay
//     [adb, "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"]  repairBlankDisplay
//     [adb, "-s", serial, "exec-out", "screencap", "-p"]             probeBlank(runData)
//   AndroidDeviceCatalog.swift
//     [adb, "devices"]                                               connectedSerials / allEmulatorSerials
//     [adb, "-s", serial, "shell", "getprop", "sys.boot_completed"]  bootCompleted
//     [adb, "-s", serial, "emu", "avd", "name"] / getprop ro.*.avd_name   avdName

import XCTest
@testable import FTAndroid

final class MonitorProbeTimeoutTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTAndroidTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// 既定はリテラルで固定する(差し替え口経由のテストだけだと既定を戻す変更が緑のまま通る)
    func testTimeoutsArePinned() {
        XCTAssertEqual(AndroidHealthProbe.adbTimeoutSeconds, 15)
        XCTAssertEqual(AndroidDeviceCatalog.adbTimeoutSeconds, 10)
    }

    func testEveryShellRunInAndroidHealthProbeCarriesATimeout() throws {
        let calls = try Self.shellCalls(
            in: repoRoot.appendingPathComponent("Sources/FTAndroid/AndroidHealthProbe.swift"))
        for expected in ["\"dumpsys\", \"SurfaceFlinger\"", "\"cmd\", \"wifi\", \"status\"",
                         "\"date\", \"+%s\"", "\"KEYCODE_SLEEP\"", "\"KEYCODE_WAKEUP\"",
                         "\"screencap\", \"-p\""] {
            XCTAssertTrue(calls.contains { $0.contains(expected) },
                          "走査が \(expected) の呼び出しを拾えていない(書式を見直す)")
        }
        let untimed = calls.filter { !$0.contains("timeout:") }
        XCTAssertEqual(untimed, [], "締切の無い Shell.run(モニターの周期を握る): \(untimed)")
    }

    func testEveryShellRunInAndroidDeviceCatalogCarriesATimeout() throws {
        let calls = try Self.shellCalls(
            in: repoRoot.appendingPathComponent("Sources/FTAndroid/AndroidDeviceCatalog.swift"))
        XCTAssertTrue(calls.contains { $0.contains("\"getprop\", \"sys.boot_completed\"") },
                      "走査が sys.boot_completed の呼び出しを拾えていない(書式を見直す)")
        let untimed = calls.filter { !$0.contains("timeout:") }
        XCTAssertEqual(untimed, [], "締切の無い Shell.run(モニターの周期を握る): \(untimed)")
    }

    /// `Shell.run(` / `Shell.runData(` の呼び出しを括弧が閉じるまでの窓で切り出す(引数は複数行に跨る)
    private static func shellCalls(in file: URL) throws -> [String] {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        var calls: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            guard let open = line.range(of: "Shell.run(") ?? line.range(of: "Shell.runData(") else { continue }
            var joined = String(line[open.lowerBound...])
            var depth = 0
            var closed = false
            for ch in joined { if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } }
            if depth <= 0 { closed = true }
            var next = index + 1
            while !closed, next < lines.count {
                joined += "\n" + lines[next]
                for ch in lines[next] { if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } }
                if depth <= 0 { closed = true }
                next += 1
            }
            calls.append(joined)
        }
        return calls
    }
}
