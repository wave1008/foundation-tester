import Foundation
import XCTest

/// ライブ操作の「自動起動待ち(placeholder)」でも毎コマンドの本人確認を飛ばさないことを、ソース走査で縛る。
/// 空きポートの採番は予約ではないので、自動起動を待つ間に run・別の serve が同じポートを取ると、
/// 期待エンジンが nil の placeholder は確認を経ずに操作を撃ち、**別のデバイスを操作する**
/// (負荷テストで実測: sim-10 の操作が run 中の sim-01 → sim-09 へ届き続けた)。
final class LivePlaceholderIdentityScanTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `return (placeholder, …)` の4つ目(期待エンジン)が nil でないこと
    func testPlaceholderReturnCarriesAnExpectedEngine() throws {
        let text = try source()
        let pattern = #"return \(placeholder,[^)]*\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertFalse(matches.isEmpty, "placeholder を返す return を1件も見つけていない — 走査が壊れている")
        for match in matches {
            let tuple = String(text[Range(match.range, in: text)!])
            let fields = tuple.dropFirst("return (".count).dropLast().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(fields.count, 4, "想定外の形: \(tuple)")
            XCTAssertNotEqual(fields.last, "nil", """
                placeholder の期待エンジンが nil — run() の毎コマンドの本人確認が飛び、自動起動を待つ間に \
                同じポートへ立った別のデバイスのブリッジへ操作が届く: \(tuple)
                """)
        }
    }

    /// 別のデバイスと判明して断ったら、同じポートに居座らず解決し直すこと(観測より前に)
    func testRefusalReResolvesBeforeObserving() throws {
        let text = try source()
        guard let refuse = text.range(of: "case .refuse(let message):") else {
            return XCTFail("liveDriftOutcome の .refuse 分岐が見つからない — 走査が壊れている")
        }
        guard let observe = text.range(of: "await emitObservation(", range: refuse.upperBound..<text.endIndex),
              let reResolve = text.range(of: "makeLiveDriver()", range: refuse.upperBound..<text.endIndex) else {
            return XCTFail(".refuse 分岐の後に makeLiveDriver() / emitObservation( が無い")
        }
        XCTAssertLessThan(reResolve.lowerBound, observe.lowerBound, """
            .refuse 分岐で解決し直す前に観測している — 前のドライバ(別のデバイス)の画面を出し、\
            同じポートに居座ったまま断り続ける
            """)
    }
}
