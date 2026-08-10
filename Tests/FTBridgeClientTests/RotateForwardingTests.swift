// `rotate(to:)`/`restoreOrientationIfNeeded()` を包むドライバが必ず素通しすることを守る。
//
// swipe と違い `status()` には default extension が無い(AppDriver の実装として毎回宣言が要る)ため、
// 「`func status() async throws -> StatusResponse` を含むファイル」は「実際に AppDriver へ準拠する
// 型を書いているファイル」の万能な目印になる。AppAttachDriver 等は既定実装(501)に頼っても
// swipe(_:) を実装していないのでスキャン対象に乗らない — rotate では既定実装への横滑りが
// 見えなくなるため、この判定源で全ファイルを取りに行く。
//
// AppDriver.swift 自身もこの文字列を含む(プロトコル要件の宣言)ので除外する。

import XCTest

final class RotateForwardingTests: XCTestCase {

    /// 対象外。**プロトコル定義と既定実装そのもの**(包む相手を持たない)
    private static let exempt: Set<String> = [
        "AppDriver.swift",
    ]

    func testEveryDriverImplementingStatusAlsoForwardsRotate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
        var offenders: [String] = []
        var checked = 0
        for dir in ["Sources/FTBridgeClient", "Sources/FTAndroid", "Sources/FTCore"] {
            let base = root.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: base,
                                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                if Self.exempt.contains(file.lastPathComponent) { continue }
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                guard source.contains("func status() async throws -> StatusResponse") else { continue }
                checked += 1
                let hasRotate = source.contains("func rotate(to orientation: FTOrientation)")
                let hasRestore = source.contains("func restoreOrientationIfNeeded()")
                if !hasRotate || !hasRestore {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(checked, 8, "走査対象が見つからない = パスかシグネチャの書式が変わった")
        XCTAssertTrue(offenders.isEmpty,
                      "AppDriver に準拠する型は rotate(to:)/restoreOrientationIfNeeded() も"
                      + "実装して包む相手へ素通しすること(既定実装に落ちると回転が無反応のまま"
                      + "成功して見える): \(offenders)")
    }
}
