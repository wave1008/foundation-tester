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

    /// swipe は ref を使わないので、attach 前(409「セッションがありません」)なら activate して
    /// 1回だけ再試行する。snapshot() を経ずに swipe が先に来るシナリオ(scrollTo が最初の操作)が
    /// あり、そのままだと 409 で落ちる(2026-07-23 に Projects/E2E-iOS の inapp 実行で顕在化。
    /// Compose 版は press のフォールバックが先に snapshot=activate していて露呈していなかった)。
    /// ref を使う tap/type/press には同じ回復を入れない: activate は refFrames をクリアするため、
    /// 再試行時には直前 snapshot の ref が別要素を指してしまう。
    public func swipe(_ direction: FTSwipeDirection) async throws {
        do {
            try await client.swipe(direction)
        } catch let error as DriverError {
            guard case .badResponse(let code, _) = error, code == 409 else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.swipe(direction)
        }
    }
    public func screenshot() async throws -> Data { try await client.screenshot() }
    public func status() async throws -> StatusResponse { try await client.status() }

    // ライフサイクル・install はアプリ本体(primary=in-app)が担う。attach 用では no-op。
    public func install(packagePath: String) async throws {}
    public func launch(bundleID: String) async throws {}
    public func terminate() async throws {}
    public var lastActionNote: String? { client.lastActionNote }
}
