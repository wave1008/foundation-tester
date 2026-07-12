// アプリ内常駐ブリッジのエントリと HTTP ルータ。dylib は SIMCTL_CHILD_DYLD_INSERT_LIBRARIES で
// 対象アプリに注入され、boot.m の構成子が FTInAppBridgeStart を呼ぶ。ポートは環境変数 FT_PORT
// (既定 8123=BridgeAPI.defaultPort)。エンドポイントは Runner/BridgeRouter と HTTP 互換にし、
// ホスト側(FTBridgeClient)を無改変で使えるようにする(単一実装原則)。
//
// ハンドラは InAppHTTPServer の accept ループ(バックグラウンド)で呼ばれる。UIKit 参照や
// タッチ合成はメインへホップし、アクションは実行後に整定(InAppSettle)を待ってから応答する。
//
// 現状(Phase 3): /status /snapshot /tap /type /swipe /press /screenshot 実装。
// /session はアプリ再起動を伴うためホスト側(BridgeProvisioner)が simctl launch+注入で担う。

import Foundation
import UIKit

@_cdecl("FTInAppBridgeStart")
public func FTInAppBridgeStart() {
    FTInAppBridge.shared.start()
}

final class FTInAppBridge {
    static let shared = FTInAppBridge()

    private var server: InAppHTTPServer?
    // 直近スナップショットの ref → window 座標フレーム / AX 要素。tap/press の解決に使う。
    // accept ループは1本ずつ処理するので単純プロパティで足りる(同時アクセスなし)。
    private var frames: [Int: CGRect] = [:]
    private var nodes: [Int: NSObject] = [:]

    func start() {
        let port = UInt16(ProcessInfo.processInfo.environment["FT_PORT"] ?? "")
            ?? BridgeAPI.defaultPort
        let server = InAppHTTPServer(port: port) { [weak self] req in
            self?.handle(req) ?? .error("bridge gone", status: 500)
        }
        // AX ツリーを materialize させる(XCUITest 相当。未活性だと label/frame が取れない)
        DispatchQueue.main.async { FTActivateAccessibility() }
        do {
            try server.start()
            self.server = server
            NSLog("FTInAppBridge listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("FTInAppBridge failed to start: \(error)")
        }
    }

    private func handle(_ req: InAppHTTPServer.Request) -> InAppHTTPServer.Response {
        do {
            switch (req.method, req.path) {
            case ("GET", "/status"): return handleStatus()
            case ("GET", "/snapshot"): return try handleSnapshot()
            case ("POST", "/tap"): return try handleTap(req.body)
            case ("POST", "/type"): return try handleType(req.body)
            case ("POST", "/swipe"): return try handleSwipe(req.body)
            case ("POST", "/press"): return try handlePress(req.body)
            case ("GET", "/screenshot"): return try handleScreenshot()
            case ("POST", "/session"):
                // in-app ブリッジは注入先アプリそのものに常駐している。ホストの launch(bundleID) は
                // 既に起動済みの当該アプリを指すので OK を返す(状態リセットが要る場合は
                // ホスト側がプロセス再起動+再注入で行う=lifecycle だけホスト責務)。
                let req = try decode(LaunchRequest.self, req.body)
                guard req.bundleID == Bundle.main.bundleIdentifier else {
                    throw InAppError(409, "in-app ブリッジは注入先アプリ(\(Bundle.main.bundleIdentifier ?? "?"))専用です(要求: \(req.bundleID))")
                }
                return .json(OKResponse())
            case ("POST", "/terminate"):
                return .error("/terminate は in-app では未対応(ホスト側でプロセス制御)", status: 501)
            default:
                return .error("not found: \(req.method) \(req.path)", status: 404)
            }
        } catch let e as InAppError {
            return .error(e.message, status: e.status)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Handlers

    private func handleStatus() -> InAppHTTPServer.Response {
        mainSync {
            let device = UIDevice.current
            return .json(StatusResponse(
                ready: true,
                device: device.name,
                osVersion: "\(device.systemName) \(device.systemVersion)",
                sessionBundleID: Bundle.main.bundleIdentifier))
        }
    }

    private func handleSnapshot() throws -> InAppHTTPServer.Response {
        try mainSync {
            guard let window = self.keyWindow() else {
                throw InAppError(409, "キーウィンドウがありません")
            }
            let result = InAppSnapshot.capture(window: window)
            self.frames = result.frames
            self.nodes = result.nodes
            return .json(SnapshotResponse(
                sessionBundleID: Bundle.main.bundleIdentifier,
                screen: result.screen,
                elements: result.elements,
                truncatedCount: result.truncated))
        }
    }

    private func handleTap(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        try performWithSettle { window in
            // ref 指定はまず accessibilityActivate(要素のデフォルトアクション=ボタン発火・
            // セル選択等を確実に起こす。合成タッチはジェスチャ認識器を発火できないため)。
            // 活性化できない要素・座標指定は合成タッチにフォールバック。
            if let ref = req.ref, let node = self.nodes[ref], node.accessibilityActivate() {
                return
            }
            let p = try self.resolvePoint(ref: req.ref, x: req.x, y: req.y)
            FTSynthTap(window, p)
        }
        return .json(OKResponse())
    }

    private func handleType(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(TypeRequest.self, body)
        if req.ref != nil {
            try performWithSettle { window in
                let p = try self.resolvePoint(ref: req.ref, x: nil, y: nil)
                FTSynthTap(window, p)
            }
        }
        var inserted = false
        try performWithSettle { _ in inserted = FTInsertTextIntoFirstResponder(req.text) }
        guard inserted else {
            throw InAppError(409, "フォーカスされた入力欄がありません(先に対象を tap してください)")
        }
        return .json(OKResponse())
    }

    private func handleSwipe(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        try performWithSettle { window in
            // スクロールのジェスチャ認識器は合成タッチでは駆動できない(tap と同じ)。
            // スクロール可能要素の contentOffset を直接動かす(accessibilityScroll は SwiftUI List で
            // 片方向しか効かず不安定だった。setContentOffset は決定的・双方向)。
            if let scrollView = Self.findScrollView(in: window) {
                Self.scrollByPage(scrollView, direction: req.direction)
            } else {
                let (from, to) = Self.swipeVector(req.direction, in: window.bounds)
                FTSynthSwipe(window, from, to, 12)
            }
        }
        return .json(OKResponse())
    }

    /// スワイプ1回 = 可視領域の ~85% 分だけ contentOffset を動かす(実機スワイプの体感に合わせる)。
    /// 指の向き=コンテンツと逆(上スワイプ=下方向へスクロール=offset.y 増)。範囲外はクランプ。
    private static func scrollByPage(_ sv: UIScrollView, direction: FTSwipeDirection) {
        let inset = sv.adjustedContentInset
        let stepY = (sv.bounds.height - inset.top - inset.bottom) * 0.85
        let stepX = (sv.bounds.width - inset.left - inset.right) * 0.85
        var offset = sv.contentOffset
        switch direction {
        case .up:    offset.y += stepY
        case .down:  offset.y -= stepY
        case .left:  offset.x += stepX
        case .right: offset.x -= stepX
        }
        let minY = -inset.top, maxY = max(-inset.top, sv.contentSize.height + inset.bottom - sv.bounds.height)
        let minX = -inset.left, maxX = max(-inset.left, sv.contentSize.width + inset.right - sv.bounds.width)
        offset.y = min(max(offset.y, minY), maxY)
        offset.x = min(max(offset.x, minX), maxX)
        sv.setContentOffset(offset, animated: false)
    }

    /// 面積最大の可視スクロールビューを返す(メインのリスト/スクロール領域)
    private static func findScrollView(in window: UIWindow) -> UIScrollView? {
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        var stack: [UIView] = [window]
        while let v = stack.popLast() {
            if let sv = v as? UIScrollView, !sv.isHidden, sv.alpha > 0.01 {
                let area = sv.bounds.width * sv.bounds.height
                if area > bestArea { best = sv; bestArea = area }
            }
            stack.append(contentsOf: v.subviews)
        }
        return best
    }

    private func handlePress(_ body: Data) throws -> InAppHTTPServer.Response {
        let req = try decode(PressRequest.self, body)
        // press は押下保持中にランループを回すため cap を duration 分広げる
        try performWithSettle(capMs: 2500 + Int(req.duration * 1000)) { window in
            let p = try self.resolvePoint(ref: req.ref, x: nil, y: nil)
            FTSynthPress(window, p, req.duration)
        }
        return .json(OKResponse())
    }

    private func handleScreenshot() throws -> InAppHTTPServer.Response {
        try mainSync {
            guard let window = self.keyWindow() else {
                throw InAppError(409, "キーウィンドウがありません")
            }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            guard let png = image.pngData() else {
                throw InAppError(500, "PNG エンコードに失敗しました")
            }
            return .png(png)
        }
    }

    // MARK: - 実行ヘルパ

    /// バックグラウンドのハンドラからメインで同期実行する。UIKit 参照用。
    private func mainSync<T>(_ block: @escaping () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try block() }
        return try DispatchQueue.main.sync { try block() }
    }

    /// メインでアクションを実行し、整定(または cap)まで待ってから返る。
    /// block 内の throw はバックグラウンド側へ伝播する。
    private func performWithSettle(capMs: Int = 2500,
                                   _ block: @escaping (UIWindow) throws -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        DispatchQueue.main.async {
            guard let window = self.keyWindow() else {
                thrown = InAppError(409, "キーウィンドウがありません")
                sem.signal()
                return
            }
            do {
                try block(window)
            } catch {
                thrown = error
                sem.signal()
                return
            }
            InAppSettle.waitOnMain(capMs: capMs) { sem.signal() }
        }
        _ = sem.wait(timeout: .now() + .milliseconds(capMs + 1500))
        if let thrown { throw thrown }
    }

    private func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
        if let ref {
            guard let frame = frames[ref] else {
                throw InAppError(404, "参照番号 [\(ref)] は未知です。先に GET /snapshot を実行してください")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let x, let y { return CGPoint(x: x, y: y) }
        throw InAppError(400, "ref または x/y が必要です")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw InAppError(400, "リクエストボディの JSON が不正です: \(error)")
        }
    }

    private static func swipeVector(_ direction: FTSwipeDirection, in bounds: CGRect) -> (CGPoint, CGPoint) {
        let cx = bounds.midX, cy = bounds.midY
        let dx = bounds.width * 0.35, dy = bounds.height * 0.35
        switch direction {
        // スワイプの向き = 指の動く向き(上スワイプ=下から上へ=コンテンツは上へスクロール)
        case .up:    return (CGPoint(x: cx, y: cy + dy), CGPoint(x: cx, y: cy - dy))
        case .down:  return (CGPoint(x: cx, y: cy - dy), CGPoint(x: cx, y: cy + dy))
        case .left:  return (CGPoint(x: cx + dx, y: cy), CGPoint(x: cx - dx, y: cy))
        case .right: return (CGPoint(x: cx - dx, y: cy), CGPoint(x: cx + dx, y: cy))
        }
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) { return key }
            if let first = windowScene.windows.first { return first }
        }
        return nil
    }
}

struct InAppError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}
