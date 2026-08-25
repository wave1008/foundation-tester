// ハイブリッドのフォールバック用ドライバ。XCUITest ブリッジを「springboard 参照(非起動)」で駆動し、
// アプリ上に載ったシステム UI(権限ダイアログ・アラート等=別プロセス)を snapshot/tap する。
// in-app ブリッジは自プロセスしか見えないので、StepExecutor が primary(in-app)で解決できないとき
// これを fallbackDriver として使う。
//
// 重要な順序契約: /session springboard はブリッジ側で「起動せず参照のみ」だが refFrames を毎回クリアする。
// そのため snapshot() でだけ session し、tap()/press() は session せず直前 snapshot の ref を使う
// (StepExecutor は snapshot→resolve→act の順で同一 driver を使うのでこれで整合する)。

import Foundation
import FTCore

public final class SystemUIDriver: AppDriver {
    private let client: BridgeClient

    /// 主ドライバが**このブリッジのセッションでアプリを駆動しているか**(engine=xcuitest = true)。
    ///
    /// true のときだけ版 79 の `/systemui/*`(セッションと ref を触らない)を使う。
    /// **hybrid では false のまま = 旧経路**: あちらの主ドライバは in-app で別プロセスなので
    /// `/session springboard` の巻き添えが無く、**変える理由が無い**。困っていたのは
    /// 共有している xcuitest だけなので、影響範囲をそこに閉じる。
    ///
    /// **ここに因果を書かないこと**(2026-08-25 の失敗): 一度は「hybrid へ寄せたら `notExist` が
    /// 0.30s → 0.07s に縮み、その 0.25s が担っていた暗黙の待ちが消えて横カルーセルが 3/3 で
    /// 落ちた」と書いた。**誤り** —— 後の 2×2 で、赤は経路ではなく **FM の生死**に完全追随すると
    /// 分かった(FM 死亡 7/7 赤 / 生存 8/8 緑。旧経路でも FM が死ねば落ちる)。
    /// 最初の対照は両群で FM の生死が揃っておらず、交絡していた
    /// (記憶 fm-alive-costs-notexist-4s の「生死を揃える」を踏んだ)。
    private let sharesPrimarySession: Bool

    public init(port: UInt16, sharesPrimarySession: Bool = false) {
        self.client = BridgeClient(port: port)
        self.sharesPrimarySession = sharesPrimarySession
    }

    public func snapshot() async throws -> SnapshotResponse {
        try await snapshot(bypassingCache: false)
    }

    /// bypassingCache 版の素通し(既定実装に任せるとフラグが落ちて最内へ届かない。
    /// SnapshotCacheBypassForwardingTests がラッパー全体でこれを守る)。
    /// **張り直しは必ずこちらに置く** —— snapshot() を素通し側にすると片方だけ張り直しを飛ばす
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        // 版 79 以降・**共有しているときだけ**: セッションを触らない専用の口。
        // engine=xcuitest はこのブリッジを主ドライバと共有しているので、旧経路
        // (`/session springboard`)を撃つとアプリのセッションと refFrames が巻き添えになり、
        // 次のステップが SpringBoard の木を読む。hybrid で使わない理由は init の doc
        if sharesPrimarySession, let scoped = try await client.systemUISnapshot() {
            usedScopedSnapshot = true
            return scoped
        }
        // hybrid(共有していない)と旧ランナー(版 < 79)。前者は巻き添えが無いので
        // 従来どおりが正しく、後者は新しい口が 404 で無い
        usedScopedSnapshot = false
        try await client.launch(bundleID: "com.apple.springboard")
        return try await client.snapshot(bypassingCache: bypassingCache)
    }

    /// 直前の snapshot がどちらの経路だったか。tap の ref を引く表が違うので取り違えない
    private var usedScopedSnapshot = false
    /// **転送必須**(既定実装に任せると最内のブリッジ接続へ届かず、上げたつもりで 120 のまま)
    public func raiseElementLimitOnNextSnapshot(_ max: Int?) {
        client.raiseElementLimitOnNextSnapshot(max)
    }
    public var supportsCacheBypass: Bool { client.supportsCacheBypass }
    public var pointScale: Double { client.pointScale }
    public var verifiesTypedText: Bool { client.verifiesTypedText }

    /// **直前の snapshot と同じ名前空間の ref を使う**(scoped は `systemRefFrames`、
    /// 旧経路は session を springboard へ移したうえでの `refFrames`)
    public func tap(ref: Int) async throws {
        if usedScopedSnapshot, try await client.systemUITap(ref: ref) { return }
        try await client.tap(ref: ref)
    }
    public func type(ref: Int?, text: String) async throws { try await client.type(ref: ref, text: text) }
    public func pressEnter() async throws { try await client.pressEnter() }
    public func clearInput(ref: Int?) async throws { try await client.clearInput(ref: ref) }
    public func hideKeyboard() async throws { try await client.hideKeyboard() }
    public func press(ref: Int, duration: Double) async throws { try await client.press(ref: ref, duration: duration) }
    public func tap(x: Double, y: Double) async throws { try await client.tap(x: x, y: y) }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await client.swipe(direction) }
    /// 用途つき版の素通し(FastLaunchDriver の注記と同じ理由)
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                      path: FTSwipePath?) async throws {
        try await client.swipe(direction, intent: intent, path: path)
    }
    /// tapAppIcon のページ送り(flickRightToLeft 相当)用。既存 /drag ルートの素通し(新規エンドポイントではない)
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await client.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                              pressSeconds: pressSeconds, durationSeconds: durationSeconds)
    }
    /// 座標ロングプレス。**既定実装(501)に落としてはいけない** —— 包む相手が実装を
    /// 持っているのに、ラッパーが黙って「未対応」を返すことになる
    public func press(x: Double, y: Double, duration: Double) async throws {
        try await client.press(x: x, y: y, duration: duration)
    }
    public func doubleTap(x: Double, y: Double) async throws { try await client.doubleTap(x: x, y: y) }
    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        try await client.rotate(to: orientation)
    }
    public func restoreOrientationIfNeeded() async throws { try await client.restoreOrientationIfNeeded() }
    public func pinch(frame: FTRect?, identifier: String?, scale: Double,
                      durationSeconds: Double) async throws {
        try await client.pinch(frame: frame, identifier: identifier, scale: scale,
                               durationSeconds: durationSeconds)
    }
    /// tapAppIcon の冒頭 home() 用。**素通しを書かないと extension の 501 既定実装に落ちる**
    /// (実機で踏んだ。SystemUIDriverHomeForwardingTests が守る)
    public func home() async throws { try await client.home() }
    public func screenshot() async throws -> Data { try await client.screenshot() }
    public func status() async throws -> StatusResponse { try await client.status() }

    // ライフサイクル・install/uninstall はアプリ本体(primary=in-app)が担う。フォールバックでは no-op。
    public func install(packagePath: String) async throws {}
    public func uninstall(bundleID: String) async throws {}
    public func launch(bundleID: String) async throws {}
    public func terminate() async throws {}
    public func clearAppData(bundleID: String) async throws {}
    // openURL は既定の 501 のまま(このクラスの用途は springboard 参照でアプリを持たない。
    // URL を配送すべき対象アプリは primary=in-app 側が持つので、そちらが受け持つ)
    // /appstate はセッション不要の読み取り。フォールバック用も実体は BridgeClient なのでそのまま使える
    public func isAppForeground(bundleID: String) async throws -> Bool {
        try await client.isAppForeground(bundleID: bundleID)
    }
    public func foregroundAppID() async throws -> String? { try await client.foregroundAppID() }
    public func systemAlert() async throws -> SystemAlertProbeResponse? { try await client.systemAlert() }
    public var lastActionNote: String? { client.lastActionNote }
}
