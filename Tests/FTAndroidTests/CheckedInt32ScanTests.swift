// Double → Int32 の座標変換は `AndroidDriver.checkedInt32(_:field:)` の1箇所だけを通す。
// `Int32(value.rounded())`(trapping init)は呼び手側の座標が `.unbounded`
// (FTCore.ArgumentBounds)なので桁外れの値(1e308 等)で **trap してプロセスごと落ちる**
// (maintainer-notes §51.1)。安全な形は `Int32(exactly: rounded)`(failable init)だけ。
// 新しい `Int32(<式>.rounded())` を Sources/FTAndroid・Sources/FTEmulatorGrpc に書いたら落ちる。

import Foundation
import XCTest

final class CheckedInt32ScanTests: XCTestCase {

    /// Sources からの相対パス → 行番号 → 許す理由
    private static let allowed: [String: [Int: String]] = [
        "FTEmulatorGrpc/EmulatorGrpcSession.swift": [
            78: "fromX/toX は呼び出し前に既に checkedInt32 を通った Int32。progress は"
                + " (0,1] なので補間結果は [min(fromX,toX), max(fromX,toX)] に収まり Int32 の外へ出ない",
            79: "同上(fromY/toY)",
        ],
    ]

    /// `Int32(exactly:)`(failable)は対象外 —— trap するのは `Int32(<式>)` の形だけ
    private static func isTrappingInt32Rounding(_ code: String) -> Bool {
        guard code.contains("Int32("), code.contains(".rounded(") else { return false }
        return !code.contains("Int32(exactly:")
    }

    func testNoTrappingInt32RoundingOutsideTheAllowlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var offenders: [String] = []
        var seenAllowed: Set<String> = []
        for dir in ["FTAndroid", "FTEmulatorGrpc"] {
            let dirURL = root.appendingPathComponent(dir)
            let names = try FileManager.default.contentsOfDirectory(atPath: dirURL.path)
                .filter { $0.hasSuffix(".swift") }
            for name in names {
                let relative = "\(dir)/\(name)"
                let source = try String(contentsOf: dirURL.appendingPathComponent(name), encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated() {
                    let lineNumber = index + 1
                    let code = line.components(separatedBy: "//")[0]
                    guard Self.isTrappingInt32Rounding(code) else { continue }
                    if let reason = Self.allowed[relative]?[lineNumber], !reason.isEmpty {
                        seenAllowed.insert("\(relative):\(lineNumber)")
                    } else {
                        offenders.append("\(relative):\(lineNumber): \(line)")
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [], """
            座標を trap する Int32(value.rounded()) で変換している箇所がある —— \
            AndroidDriver.checkedInt32(_:field:)(Int32(exactly:) を使う)へ寄せる。\
            trap しないと分かっているなら allowed に行番号と理由を書く
            """)
        let expected = Set(Self.allowed.flatMap { file, lines in lines.keys.map { "\(file):\($0)" } })
        XCTAssertEqual(seenAllowed, expected,
                       "allowed に載っている行が実在しない、または行番号がずれた(コードを直したら登録も直す)")
    }
}
