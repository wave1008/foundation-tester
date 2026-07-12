// アプリ内常駐ブリッジのエントリと HTTP ルータ。dylib は SIMCTL_CHILD_DYLD_INSERT_LIBRARIES で
// 対象アプリに注入され、boot.m の構成子が FTInAppBridgeStart を呼ぶ。ポートは環境変数 FT_PORT
// (既定 8123=BridgeAPI.defaultPort)。エンドポイントは Runner/BridgeRouter と HTTP 互換にし、
// ホスト側(FTBridgeClient)を無改変で使えるようにする(単一実装原則)。
//
// 現状(Phase 3 足場): /status と /snapshot のみ実装。tap/type/swipe/press/session/screenshot は
// 501(未実装)。整定待ちとタッチ合成は後続で追加する。

import Foundation
import UIKit

@_cdecl("FTInAppBridgeStart")
public func FTInAppBridgeStart() {
    FTInAppBridge.shared.start()
}

final class FTInAppBridge {
    static let shared = FTInAppBridge()

    private var server: InAppHTTPServer?
    private var frames: [Int: CGRect] = [:]

    func start() {
        let port = UInt16(ProcessInfo.processInfo.environment["FT_PORT"] ?? "")
            ?? BridgeAPI.defaultPort
        let server = InAppHTTPServer(port: port) { [weak self] req in
            self?.handle(req) ?? .error("bridge gone", status: 500)
        }
        do {
            try server.start()
            self.server = server
            NSLog("FTInAppBridge listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("FTInAppBridge failed to start: \(error)")
        }
    }

    private func handle(_ req: InAppHTTPServer.Request) -> InAppHTTPServer.Response {
        switch (req.method, req.path) {
        case ("GET", "/status"): return handleStatus()
        case ("GET", "/snapshot"): return handleSnapshot()
        case ("POST", "/session"), ("POST", "/tap"), ("POST", "/type"),
             ("POST", "/swipe"), ("POST", "/press"), ("GET", "/screenshot"),
             ("POST", "/terminate"):
            return .error("未実装(Phase 3 足場): \(req.method) \(req.path)", status: 501)
        default:
            return .error("not found: \(req.method) \(req.path)", status: 404)
        }
    }

    private func handleStatus() -> InAppHTTPServer.Response {
        let device = UIDevice.current
        return .json(StatusResponse(
            ready: true,
            device: device.name,
            osVersion: "\(device.systemName) \(device.systemVersion)",
            sessionBundleID: Bundle.main.bundleIdentifier))
    }

    private func handleSnapshot() -> InAppHTTPServer.Response {
        guard let window = keyWindow() else {
            return .error("キーウィンドウがありません", status: 409)
        }
        let result = InAppSnapshot.capture(window: window)
        frames = result.frames
        return .json(SnapshotResponse(
            sessionBundleID: Bundle.main.bundleIdentifier,
            screen: result.screen,
            elements: result.elements,
            truncatedCount: result.truncated))
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
