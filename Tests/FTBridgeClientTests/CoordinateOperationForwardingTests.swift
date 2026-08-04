// **座標で完結する操作**(ref を使わないので誰が受けても同じ結果になる操作)を、
// XCUITest ブリッジを包むドライバが全て素通ししていることを守る。
//
// AppDriver はこれらに既定実装(501)を持つ。ラッパーが1つ書き忘れても**コンパイルは通り**、
// 包む相手が実装を持っているのに「このエンジンでは未対応」と返す。しかもフォールバック先が
// これを返すと、ホストから見ると**どちらの経路でも 501** = 打つ手なしに見える
// (2026-08-04 に AppAttachDriver の座標長押しで実際に踏み、SystemUIDriver にも同じ穴があった)。
//
// 型を並べず**ソース走査**にしてあるのは SwipeForScrollForwardingTests と同じ理由:
// 新しいラッパーを足したときも自動的に対象になる。

import XCTest

final class CoordinateOperationForwardingTests: XCTestCase {

    /// 走査対象。**XCUITest ブリッジを包み、フォールバック先になり得るドライバ**だけを入れる
    /// (in-app 側は「このエンジンでは不可」を返すのが仕事なので対象外)
    private static let wrappers = [
        "AppAttachDriver.swift", "SystemUIDriver.swift",
        "FastLaunchDriver.swift", "LaunchPreflightDriver.swift", "SessionRecoveryDriver.swift",
    ]

    /// 座標・identifier で完結する操作(ref を渡さないので経路を跨いでも意味が変わらない)。
    /// **ここに足すのは「ラッパーが黙って 501 を返すと事故になる」操作だけ**
    private static let operations: [String: String] = [
        "drag": "func drag(",
        "press(x:y:)": "func press(x:",
        "doubleTap": "func doubleTap(",
        "pinch": "func pinch(",
    ]

    func testCoordinateOperationsAreForwardedByEveryWrapper() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FTBridgeClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリルート
            .appendingPathComponent("Sources/FTBridgeClient")

        var missing: [String] = []
        for wrapper in Self.wrappers {
            let source = try String(contentsOf: base.appendingPathComponent(wrapper), encoding: .utf8)
            for (name, signature) in Self.operations.sorted(by: { $0.key < $1.key })
            where !source.contains(signature) {
                missing.append("\(wrapper): \(name)")
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "座標で完結する操作は必ず素通しすること(既定実装の 501 に落ちると、"
                          + "包む相手が実装を持っているのに未対応として返る): \(missing)")
    }

    /// 走査対象のファイルが実在すること(改名で**空振りしたまま緑**になるのを防ぐ)
    func testWrapperFilesExist() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTBridgeClient")
        for wrapper in Self.wrappers {
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                base.appendingPathComponent(wrapper).path),
                "\(wrapper) が見つかりません(改名したらこのテストの一覧も直すこと)")
        }
    }
}
