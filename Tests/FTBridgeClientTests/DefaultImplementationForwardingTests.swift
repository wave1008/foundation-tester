// **AppDriver の「501 を投げる既定実装」に、ラッパーが黙って落ちていないこと**を守る。
//
// 既定実装があるとラッパーが素通しを書き忘れても**コンパイルは通り**、包む相手が実装を
// 持っているのに「このエンジンでは未対応」を返す。**フォールバック先がこれを返すと、
// ホストからは「どちらの経路でも 501」= 打つ手なし**に見える
// (2026-08-04 に AppAttachDriver の座標長押しで踏み、掃討したら SystemUIDriver にもあった)。
//
// **対象の操作は AppDriver.swift から導出する**(一覧を手書きしない)。手書きだと
// 「新しい操作を足したときに一覧の更新を忘れる」= 同じ穴が新メソッドで再発する。
// 意図的な非対応だけを exempt に理由つきで書く —— 追加のたびに判断を迫るのが目的。

import XCTest

final class DefaultImplementationForwardingTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
    }

    /// 意図的に持たない組み合わせ("<ドライバ>.<操作>" → 理由)。
    /// **経路上ここへ到達しないもの以外は入れない**(入れた瞬間に防波堤の穴になる)
    private static let exempt: [String: String] = [
        // SystemUIDriver は springboard 参照(tapAppIcon のホーム画面走査)専用。
        // back / appSwitcher は systemDriver(hybrid では AppAttachDriver)が受けるため到達しない
        "SystemUIDriver.back": "springboard 参照専用。back は systemDriver が受ける",
        "SystemUIDriver.openAppSwitcher": "同上(appSwitcher も systemDriver が受ける)",
    ]

    /// オーバーロードがあり、名前だけでは検出できない操作の実シグネチャ
    private static let overloaded: [String: String] = ["press": "func press(x:"]

    /// AppDriver.swift の `public extension` から「501 を投げる既定実装」の名前を採る
    private func defaultImplementedOperations() throws -> [String] {
        let source = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/FTCore/AppDriver.swift"), encoding: .utf8)
        guard let range = source.range(of: "public extension AppDriver") else {
            XCTFail("AppDriver の既定実装ブロックが見つかりません(構造が変わった)")
            return []
        }
        var found: [String] = []
        var pending: String?
        for line in source[range.lowerBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("func "), let paren = text.dropFirst(5).firstIndex(of: "(") {
                pending = String(text.dropFirst(5)[..<paren])
            }
            // 直前に見た func の本体が 501 を投げていれば「素通しを書き忘れると黙る」操作
            if text.contains("throw DriverError.badResponse(status: 501"), let name = pending {
                found.append(name)
                pending = nil
            }
        }
        return found
    }

    func testWrappersDoNotFallToDefaultImplementations() throws {
        let operations = try defaultImplementedOperations()
        XCTAssertGreaterThan(operations.count, 5,
                             "既定実装を抽出できていない(AppDriver.swift の書式が変わった)")

        let driversDir = Self.repoRoot.appendingPathComponent("Sources/FTBridgeClient")
        let files = try FileManager.default.contentsOfDirectory(at: driversDir,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("Driver.swift") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 4, "走査対象のドライバが見つからない")

        var missing: [String] = []
        for file in files {
            let name = String(file.lastPathComponent.dropLast(".swift".count))
            let source = try String(contentsOf: file, encoding: .utf8)
            for operation in operations {
                if Self.exempt["\(name).\(operation)"] != nil { continue }
                let signature = Self.overloaded[operation] ?? "func \(operation)("
                if !source.contains(signature) { missing.append("\(name).\(operation)") }
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "既定実装(501)に落ちています。包む相手へ素通しするか、到達しないなら"
                          + " exempt へ理由つきで登録すること: \(missing.sorted())")
    }

    /// exempt が実在の組み合わせだけを指していること(古い名前が残ると穴になる)
    func testExemptEntriesStillExist() throws {
        let operations = Set(try defaultImplementedOperations())
        for key in Self.exempt.keys {
            let parts = key.split(separator: ".")
            XCTAssertEqual(parts.count, 2, "exempt のキーは <ドライバ>.<操作>: \(key)")
            let driver = Self.repoRoot
                .appendingPathComponent("Sources/FTBridgeClient/\(parts[0]).swift")
            XCTAssertTrue(FileManager.default.fileExists(atPath: driver.path),
                          "exempt のドライバが実在しません: \(key)")
            XCTAssertTrue(operations.contains(String(parts[1])),
                          "exempt の操作が既定実装の一覧にありません(不要になった可能性): \(key)")
        }
    }
}
