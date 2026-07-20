// hybrid で Compose 等 UIKit 非依存アプリの type を XCUITest 実行するための attach 用ドライバ。
// springboard 参照の SystemUIDriver とは別用途(こちらはテスト対象アプリ自身に attach する)。
//
// 順序契約は SystemUIDriver と同じ: activate は refFrames をクリアするため snapshot() でのみ
// activate し、tap()/type()/press() は session せず直前 snapshot の ref を使う。

import Foundation
import FTCore

public final class AppAttachDriver: AppDriver {
    private let client: BridgeClient
    private let bundleID: String

    public init(port: UInt16, bundleID: String) {
        self.client = BridgeClient(port: port)
        self.bundleID = bundleID
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await client.activate(bundleID: bundleID)
        return try await client.snapshot()
    }

    public func tap(ref: Int) async throws { try await client.tap(ref: ref) }
    public func type(ref: Int?, text: String) async throws { try await client.type(ref: ref, text: text) }
    public func press(ref: Int, duration: Double) async throws { try await client.press(ref: ref, duration: duration) }
    public func tap(x: Double, y: Double) async throws { try await client.tap(x: x, y: y) }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await client.swipe(direction) }
    public func screenshot() async throws -> Data { try await client.screenshot() }
    public func status() async throws -> StatusResponse { try await client.status() }

    // ライフサイクル・install はアプリ本体(primary=in-app)が担う。attach 用では no-op。
    public func install(packagePath: String) async throws {}
    public func launch(bundleID: String) async throws {}
    public func terminate() async throws {}
}
