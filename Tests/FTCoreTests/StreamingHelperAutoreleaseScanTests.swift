// **画面を取り込み続ける常駐ヘルパーの主ループは autoreleasepool で区切る**。
//
// 1 周ごとに作るのは「取得した PNG(`URLSession` / `adb` の Data)」と「縮小の中間物
// (Core Graphics の CGImage / CGImageSource)」で、どちらも autoreleased。**トップレベルの
// 抜けないループには pool が1つも無い**ので、区切らないと1枚も解放されないまま回り続ける。
// 実害(2026-09-22 の負荷テスト): `fleetest-devicepoll` が実機 1 台の配信で **1 時間 15 分に 71 GB**
// (≒ 55 GB/時)。`AvailableDataAutoreleaseScanTests` と同じ型だが、あちらは 630 MB/時 ——
// **こちらは画像なので桁が2つ違う**(物理 192 GB の Mac がメモリ不足のダイアログを出した)。
//
// 判定は2段: ①取り込み系ヘルパーの集合を等号で固定(新しいヘルパーを足して忘れると落ちる)
// ②その主ループ(`while true`)の直後に pool があること(devicepoll の形を固定)。

import Foundation
import XCTest

final class StreamingHelperAutoreleaseScanTests: XCTestCase {

    /// **画面を取り込み続ける**常駐ヘルパー。増やしたらここへ足す(等号照合なので漏れは落ちる)。
    /// `fleetest-mcp` は入れない —— 常駐だが 1 リクエスト = 1 応答で、抜けない取り込みループを持たない
    private static let capturingHelpers: Set<String> = [
        "fleetest-devicepoll",
        "fleetest-simstream",
        "fleetest-androidstream",
    ]

    /// 画像を作る行から上へ pool を探す行数(宣言・コメントを挟んでよい)
    private static let lookback = 12

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// ①集合そのものを固定する。**`Sources/fleetest-*` のうち「stdout へ映像を流し続ける」もの**。
    /// `fleetest-mcp` は `ImageDownscale` を使うが 1 リクエスト = 1 応答なので対象外(抜けない
    /// 取り込みループを持たない) —— だから中身の目印ではなく**名前で固定**する
    func testTheCapturingHelperSetIsPinned() throws {
        let root = sourcesRoot()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("fleetest-") })
        XCTAssertTrue(Self.capturingHelpers.isSubset(of: names),
                      "固定している取り込みヘルパーが Sources に無い: "
                      + Self.capturingHelpers.subtracting(names).sorted().joined(separator: ", "))
        // 新しい `fleetest-*` が増えたら、取り込み系かどうかを人が判断してこの集合を更新する
        XCTAssertEqual(names.subtracting(Self.capturingHelpers), ["fleetest-mcp"],
                       "`Sources/fleetest-*` が増減した —— 取り込み系なら capturingHelpers へ足し、"
                       + "主ループを autoreleasepool で区切ること")
    }

    /// ②**画像を作る行が pool の内側にあること**。全部の `while true` を見ない ——
    /// stdin を `read(2)` で待つだけのループは Foundation のオブジェクトを1つも作らないので
    /// 区切りは要らない(devicepoll:130)。対象は「1周ごとに画像を作る」呼び出しだけ
    func testEveryCaptureIsInsideAnAutoreleasePool() throws {
        let root = sourcesRoot()
        var offenders: [String] = []
        var captures = 0
        for helper in Self.capturingHelpers.sorted() {
            let dir = root.appendingPathComponent(helper)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            // **ObjC の `main.m` も見る**(simstream / androidstream は ObjC)
            for case let url as URL in files where ["swift", "m"].contains(url.pathExtension) {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                let code = lines.map { $0.components(separatedBy: "//")[0] }
                // ObjC: `main` を囲む pool は戻らない `dispatch_main()` も囲むので**一度も空にならない**。
                // フレームの処理は gQueue(GCD)の上で、暗黙の pool はキューが空になるまで空かない。
                // だから1フレームごとに入る関数の本体を pool で始める(下の objcFrameEntries)
                if url.pathExtension == "m" {
                    captures += 1
                    offenders += Self.objcOffenders(helper: helper, file: url.lastPathComponent, code: code)
                    continue
                }
                for (index, line) in code.enumerated() where line.contains("ImageDownscale.") {
                    captures += 1
                    let window = code[max(0, index - Self.lookback)...index]
                    if !window.contains(where: { $0.contains("autoreleasepool") }) {
                        offenders.append("\(helper)/\(url.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(captures, 3, "取り込みの呼び出しが見つからない —— 走査の前提が崩れた")
        XCTAssertEqual(offenders, [],
                       "1周ごとに作る画像を autoreleasepool の外で作っている(抜けないループでは1枚も"
                       + "解放されない。2026-09-22: devicepoll が 55 GB/時): "
                       + offenders.joined(separator: ", "))
    }

    /// ObjC ヘルパーで**1フレームごとに入る関数**。本体の最初の文が `@autoreleasepool` であること。
    /// 増えたら足す(画像を作る行がこの外にあると下の走査が落とす)
    private static let objcFrameEntries: [String: Set<String>] = [
        "fleetest-simstream": ["ftEmitNow", "ftEmitNowH264", "ftHandleEncodedSample"],
        "fleetest-androidstream": ["ftEncodeAndEmit", "processChunk"],
    ]

    /// 1フレームごとに作る autoreleased な画像の目印(CIImage を CVBuffer から作る呼び出し)
    private static let objcFrameImageMarkers = ["imageWithCVPixelBuffer", "imageWithCVImageBuffer"]

    static func objcOffenders(helper: String, file: String, code: [String]) -> [String] {
        var offenders: [String] = []
        let entries = objcFrameEntries[helper] ?? []
        /// `static <型> name(` の定義行(前方宣言 `;` は除く)
        func definition(of line: String) -> String? {
            guard line.hasPrefix("static "), !line.trimmingCharacters(in: .whitespaces).hasSuffix(";"),
                  let paren = line.firstIndex(of: "(") else { return nil }
            return line[..<paren].split(whereSeparator: { $0 == " " || $0 == "*" }).last.map(String.init)
        }
        var found: Set<String> = []
        for (index, line) in code.enumerated() {
            guard let name = definition(of: line), entries.contains(name) else { continue }
            found.insert(name)
            let firstStatement = code[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if firstStatement?.trimmingCharacters(in: .whitespaces).hasPrefix("@autoreleasepool") != true {
                offenders.append("\(helper)/\(file):\(index + 1) \(name) の本体が @autoreleasepool で始まらない")
            }
        }
        for missing in entries.subtracting(found).sorted() {
            offenders.append("\(helper)/\(file): \(missing) が見つからない(改名したら objcFrameEntries も直す)")
        }
        for (index, line) in code.enumerated() {
            if objcFrameImageMarkers.contains(where: { line.contains($0) }) {
                let owner = code[...index].reversed().lazy.compactMap(definition).first
                if !(owner.map(entries.contains) ?? false) {
                    offenders.append("\(helper)/\(file):\(index + 1) 1フレームごとの画像を"
                        + " objcFrameEntries の外(\(owner ?? "?"))で作っている")
                }
            }
            if line.contains(".availableData") {
                let window = code[max(0, index - 2)..<index]
                if !window.contains(where: { $0.contains("@autoreleasepool") }) {
                    offenders.append("\(helper)/\(file):\(index + 1) availableData が @autoreleasepool の外")
                }
            }
        }
        return offenders
    }
}
