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
    /// このインスタンスで一度でも attach(activate)したか。
    ///
    /// **XCUITest ブリッジは run 内で使い回される**(別プロジェクト・別シナリオ間で再利用)ため、
    /// セッションが**前に attach した別アプリ**を指したまま来ることがある。その状態で ref 無しの
    /// ジェスチャを撃つと、ブリッジは「セッションはある」ので 409 を返さず、XCUI が
    /// `application ... is not running` で失敗する(2026-07-28 実測: E2E-iOS の次に E2E-Flutter を
    /// 回した run で、Flutter の scrollTo が com.ftester.e2e.ios を掴んで失敗)。
    /// **ランナーはこの失敗でプロセスごと落ちる**(BridgeRouter.requireLiveApp のコメント参照)ため、
    /// 撃つ前に対象を自分の bundleID へ揃える。activate は refFrames をクリアするので
    /// **1インスタンス1回だけ**(= 1シナリオ1回。以降は snapshot() の activate が維持する)
    private var attached = false

    public init(port: UInt16, bundleID: String) {
        self.client = BridgeClient(port: port)
        self.bundleID = bundleID
    }

    /// ref を使わない操作の前に呼ぶ。ref を使う操作からは呼ばない(直前 snapshot で
    /// attached=true になっており、ここで activate すると refFrames が消えて別要素を指す)
    private func ensureAttached() async throws {
        guard !attached else { return }
        try await client.activate(bundleID: bundleID)
        attached = true
    }

    /// 409(セッション無し)と 503(セッションはあるがアプリが起動していない)は
    /// どちらも「attach し直せば通る」= 回復対象。**ref を使う操作では使わない**
    private static func isRecoverableSession(_ error: Error) -> Bool {
        guard let error = error as? DriverError,
              case .badResponse(let code, _) = error else { return false }
        return code == 409 || code == 503
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await snapshot(bypassingCache: false)
    }

    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)。
    /// **attach の前処理は必ずこちらに置く** —— snapshot() を素通し側にすると片方だけ attach を飛ばす
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await client.activate(bundleID: bundleID)
        attached = true
        return try await client.snapshot(bypassingCache: bypassingCache)
    }
    public var supportsCacheBypass: Bool { client.supportsCacheBypass }

    public func tap(ref: Int) async throws { try await client.tap(ref: ref) }
    /// ref 無し(フォーカス中要素への入力)は swipe と同じ回復を入れる(下の swipe のコメント参照)。
    /// **ref 有りには入れない**: activate が refFrames をクリアするため再試行時に別要素を指す
    public func type(ref: Int?, text: String) async throws {
        guard ref == nil else { return try await client.type(ref: ref, text: text) }
        try await ensureAttached()
        do {
            try await client.type(ref: nil, text: text)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.type(ref: nil, text: text)
        }
    }
    /// pressEnter も ref を使わないので swipe と同じ回復を入れる(下の swipe のコメント参照)。
    /// in-app が 409 を返して初めてここへ来るため、attach 前=セッション無しに当たりやすい
    public func pressEnter() async throws {
        try await ensureAttached()
        do {
            try await client.pressEnter()
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.pressEnter()
        }
    }
    public func press(ref: Int, duration: Double) async throws { try await client.press(ref: ref, duration: duration) }
    public func tap(x: Double, y: Double) async throws { try await client.tap(x: x, y: y) }

    /// ref を使わないので pressEnter と同じ回復を入れる(上の pressEnter のコメント参照)
    public func hideKeyboard() async throws {
        try await ensureAttached()
        do {
            try await client.hideKeyboard()
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.hideKeyboard()
        }
    }

    /// ref 無し(フォーカス中要素のクリア)は type と同じ回復を入れる。ref 有りには入れない
    /// (activate が refFrames をクリアするため再試行時に別要素を指す)
    public func clearInput(ref: Int?) async throws {
        guard ref == nil else { return try await client.clearInput(ref: ref) }
        try await ensureAttached()
        do {
            try await client.clearInput(ref: nil)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.clearInput(ref: nil)
        }
    }

    /// back は drag と同じ扱い(座標操作でセッションが要る。BridgeClient.back() は内部で
    /// snapshot+drag するため home/appSwitcher のようなセッション不要経路ではない)
    public func back() async throws {
        try await ensureAttached()
        do {
            try await client.back()
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.back()
        }
    }

    /// swipe は ref を使わないので、事前に attach を揃え(ensureAttached)、それでも
    /// 409/503 なら activate して1回だけ再試行する。snapshot() を経ずに swipe が先に来るシナリオ
    /// (scrollTo が最初の操作)が
    /// あり、そのままだと 409 で落ちる(2026-07-23 に Projects/E2E-iOS の inapp 実行で顕在化。
    /// Compose 版は press のフォールバックが先に snapshot=activate していて露呈していなかった)。
    /// ref を使う tap/type/press には同じ回復を入れない: activate は refFrames をクリアするため、
    /// 再試行時には直前 snapshot の ref が別要素を指してしまう。
    public func swipe(_ direction: FTSwipeDirection) async throws {
        try await swipe(direction, intent: .gesture, path: nil)
    }

    /// 用途つき版の素通し(FastLaunchDriver の注記と同じ理由)。
    /// **client.swipe へ intent と path を渡す**(落とすと用途別のジェスチャ調整と
    /// スクロール領域の指定が丸ごと効かなくなる)
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        try await ensureAttached()
        do {
            try await client.swipe(direction, intent: intent, path: path)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.swipe(direction, intent: intent, path: path)
        }
    }
    /// drag も ref を使わないので swipe と同じ 409 回復を入れる(座標は対象アプリのセッションが要る)。
    /// in-app は drag を実装しないため、hybrid のスクロール探索の空打ちはここへ回ってくる
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await ensureAttached()
        do {
            try await client.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                  pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                  pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        }
    }

    /// 座標ロングプレスも ref を使わないので drag と同じ 409 回復を入れる。
    /// **既定実装(501)に落としてはいけない**: hybrid のフォールバックで in-app が長押しを
    /// 持たない(501)ぶんをここが受けるため、無いと「どちらの経路でも 501」になる
    /// (2026-08-04 に MCP のエンジン追従で実際に踏んだ)
    public func press(x: Double, y: Double, duration: Double) async throws {
        try await ensureAttached()
        do {
            try await client.press(x: x, y: y, duration: duration)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.press(x: x, y: y, duration: duration)
        }
    }

    /// doubleTap / pinch も ref を使わない(座標・identifier)ので drag と同じ 409 回復を入れる。
    /// in-app は多点ジェスチャを持たないため、hybrid のピンチはここへ回ってくる
    public func doubleTap(x: Double, y: Double) async throws {
        try await ensureAttached()
        do {
            try await client.doubleTap(x: x, y: y)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.doubleTap(x: x, y: y)
        }
    }

    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await ensureAttached()
        do {
            try await client.pinch(frame: frame, identifier: identifier, scale: scale,
                                   durationSeconds: durationSeconds)
        } catch {
            guard Self.isRecoverableSession(error) else { throw error }
            try await client.activate(bundleID: bundleID)
            try await client.pinch(frame: frame, identifier: identifier, scale: scale,
                                   durationSeconds: durationSeconds)
        }
    }

    /// home / appSwitcher は XCUITest ブリッジ側が**セッション不要**で処理する
    /// (XCUIDevice / springboard 座標。Runner の BridgeRouter.handleHome / handleAppSwitcher)。
    /// activate を挟まない = 対象アプリを前面に戻してしまわない
    public func home() async throws { try await client.home() }
    public func openAppSwitcher() async throws { try await client.openAppSwitcher() }

    public func screenshot() async throws -> Data { try await client.screenshot() }
    public func status() async throws -> StatusResponse { try await client.status() }

    // ライフサイクル・install/uninstall はアプリ本体(primary=in-app)が担う。attach 用では no-op。
    public func install(packagePath: String) async throws {}
    public func uninstall(bundleID: String) async throws {}
    public func launch(bundleID: String) async throws {}
    public func terminate() async throws {}
    public func clearAppData(bundleID: String) async throws {}
    // /appstate はセッション不要の読み取り。attach 用も実体は BridgeClient なのでそのまま使える
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await client.isAppForeground(bundleID: bundleID)
    }
    public func foregroundAppID() async throws -> String? { try await client.foregroundAppID() }
    public var lastActionNote: String? { client.lastActionNote }
}
