// BridgeRouter.swift
// HTTPリクエストを XCUITest 操作に変換する。
// スナップショットの圧縮(フィルタ・set-of-mark参照番号付与)はここで行い、
// ホストへ生ツリーを送らない(4Kトークン対策)。

import Foundation
import UIKit
import XCTest

struct BridgeError: Error {
    let status: Int
    let message: String

    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

final class BridgeRouter {

    // 現在のセッション状態。直近スナップショットの ref→frame 対応表を保持し、
    // tap/press は座標タップとして解決する(要素クエリ再構築より頑健)。
    private var app: XCUIApplication?
    private var sessionBundleID: String?
    private var refFrames: [Int: CGRect] = [:]

    private let decoder = JSONDecoder()

    func handle(_ request: BridgeHTTPServer.Request) -> BridgeHTTPServer.Response {
        do {
            switch (request.method, request.path) {
            case ("GET", "/status"): return handleStatus()
            case ("POST", "/session"): return try handleLaunch(request.body)
            case ("GET", "/snapshot"): return try handleSnapshot()
            case ("POST", "/tap"): return try handleTap(request.body)
            case ("POST", "/type"): return try handleType(request.body)
            case ("POST", "/swipe"): return try handleSwipe(request.body)
            case ("POST", "/drag"): return try handleDrag(request.body)
            case ("POST", "/press"): return try handlePress(request.body)
            case ("GET", "/screenshot"): return handleScreenshot()
            case ("POST", "/appswitcher"): return try handleAppSwitcher()
            case ("POST", "/home"): return try handleHome()
            case ("POST", "/terminate"): return try handleTerminate()
            default:
                return .error("not found: \(request.method) \(request.path)", status: 404)
            }
        } catch let error as BridgeError {
            return .error(error.message, status: error.status)
        } catch {
            return .error("\(error)", status: 500)
        }
    }

    // MARK: - Handlers

    private func handleStatus() -> BridgeHTTPServer.Response {
        let device = UIDevice.current
        return .json(StatusResponse(
            ready: true,
            device: device.name,
            osVersion: "\(device.systemName) \(device.systemVersion)",
            sessionBundleID: sessionBundleID,
            engine: "xcuitest",
            protocolVersion: BridgeAPI.bridgeProtocolVersion,
            fastInputAvailable: FastInput.available))
    }

    private func handleLaunch(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(LaunchRequest.self, body)
        let target = XCUIApplication(bundleIdentifier: req.bundleID)
        // springboard は起動せず参照のみ(launch するとホームに飛びシステムアラートを消す。
        // ハイブリッドのフォールバックで、アプリ上に載ったシステム UI を非破壊で走査/操作するため)。
        if req.bundleID == "com.apple.springboard" {
            app = target
            sessionBundleID = req.bundleID
            refFrames = [:]
            return .json(OKResponse())
        }
        if req.attachOnly == true {
            // simctl 等で起動済みのアプリへのプロキシ接続のみ(activate() の約1s を払わない。
            // 前面到達の確認だけ行う=未起動なら即エラーで呼び出し側が診断できる)
            guard target.state == .runningForeground
                || target.wait(for: .runningForeground, timeout: 5) else {
                throw BridgeError(500, "attach 対象アプリが前面にありません: \(req.bundleID)"
                    + "(simctl launch の成否を確認してください)")
            }
        } else if req.activate == true {
            target.activate()
        } else {
            target.launch()
        }
        guard target.state == .runningForeground || target.wait(for: .runningForeground, timeout: 10) else {
            throw BridgeError(500, "アプリを起動できませんでした: \(req.bundleID)(インストール済みか確認してください)")
        }
        app = target
        sessionBundleID = req.bundleID
        refFrames = [:]
        return .json(OKResponse())
    }

    private func handleSnapshot() throws -> BridgeHTTPServer.Response {
        let app = try requireApp()
        let root = try app.snapshot()
        let screen = root.frame

        var elements: [ElementInfo] = []
        var frames: [Int: CGRect] = [:]
        var truncated = 0
        collect(root, depth: 0, screen: screen,
                elements: &elements, frames: &frames, truncated: &truncated)

        refFrames = frames
        return .json(SnapshotResponse(
            sessionBundleID: sessionBundleID,
            screen: FTRect(x: screen.origin.x, y: screen.origin.y,
                           width: screen.width, height: screen.height),
            elements: elements,
            truncatedCount: truncated))
    }

    private func handleTap(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TapRequest.self, body)
        let app = try requireApp()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        try FastInput.with(req.fast) {
            coordinate(app, point).tap()
        }
        return .json(OKResponse())
    }

    private func handleType(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(TypeRequest.self, body)
        let app = try requireApp()
        if let ref = req.ref {
            // tap() が quiescence まで待つため追加待ちは不要(旧: 固定400ms・keyboards クエリは
            // キーボードが別プロセス扱いのため常にタイムアウトし逆効果だった。2026-07-12実測)
            coordinate(app, try resolvePoint(ref: ref, x: nil, y: nil)).tap()
        }
        app.typeText(req.text)
        return .json(OKResponse())
    }

    private func handleSwipe(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(SwipeRequest.self, body)
        let app = try requireApp()
        FastInput.with(req.fast) {
            switch req.direction {
            case .up: app.swipeUp()
            case .down: app.swipeDown()
            case .left: app.swipeLeft()
            case .right: app.swipeRight()
            }
        }
        return .json(OKResponse())
    }

    /// 2点間ドラッグ(座標は tap と同じポイント座標)。press=静止時間で長押し→ドラッグを再現し、
    /// velocity=距離÷移動時間で「ゆっくりドラッグ(慣性なし)〜フリック」を再現する
    private func handleDrag(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(DragRequest.self, body)
        let app = try requireApp()
        let from = coordinate(app, CGPoint(x: req.fromX, y: req.fromY))
        let to = coordinate(app, CGPoint(x: req.toX, y: req.toY))
        let press = max(req.press ?? 0.05, 0.05)
        guard let requestedDuration = req.duration else {
            from.press(forDuration: press, thenDragTo: to)
            return .json(OKResponse())
        }
        let distance = hypot(req.toX - req.fromX, req.toY - req.fromY)
        let duration = max(requestedDuration, 0.05)
        // velocity の単位は pt/秒。極端値はクランプ(0除算・非現実的な速度の防止)
        let velocity = max(10.0, min(distance / duration, 5000.0))
        from.press(forDuration: press, thenDragTo: to,
                   withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
        return .json(OKResponse())
    }

    private func handlePress(_ body: Data) throws -> BridgeHTTPServer.Response {
        let req = try decode(PressRequest.self, body)
        let app = try requireApp()
        let point = try resolvePoint(ref: req.ref, x: req.x, y: req.y)
        try FastInput.with(req.fast) {
            coordinate(app, point).press(forDuration: req.duration)
        }
        return .json(OKResponse())
    }

    private func handleScreenshot() -> BridgeHTTPServer.Response {
        .png(XCUIScreen.main.screenshot().pngRepresentation)
    }

    /// 画面下端からのスワイプ上げ+ホールドでアプリスイッチャーを開く(Face ID 機にはホームボタン
    /// APIが無いためジェスチャで行う)。座標は springboard 参照(セッション不要・HID合成なので
    /// 前面アプリに関係なく効く)。velocity/hold はシミュレータ実機で調整済みの値。
    private func handleAppSwitcher() throws -> BridgeHTTPServer.Response {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.999))
        let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 1.0)
        return .json(OKResponse())
    }

    /// ホーム画面に戻る(セッション不要。XCUIDevice のホームボタン押下=前面アプリに関係なく効く)
    private func handleHome() throws -> BridgeHTTPServer.Response {
        XCUIDevice.shared.press(.home)
        return .json(OKResponse())
    }

    private func handleTerminate() throws -> BridgeHTTPServer.Response {
        let app = try requireApp()
        // 未起動での terminate() は NSException(Code=10001「is not running」)を投げ、
        // BridgeHTTPServer の例外シムで 500 化する。state で回避し、
        // チェック〜呼び出し間のレースで投げられた「is not running」だけは握り潰して冪等にする。
        if app.state != .notRunning && app.state != .unknown {
            if let ex = FTCatchObjCException({ app.terminate() }), !ex.contains("is not running") {
                throw BridgeError(500, "アプリの終了に失敗しました: \(ex)")
            }
        }
        self.app = nil
        sessionBundleID = nil
        refFrames = [:]
        return .json(OKResponse())
    }

    // MARK: - スナップショット収集・フィルタ

    private func collect(_ node: XCUIElementSnapshot, depth: Int, screen: CGRect,
                         elements: inout [ElementInfo], frames: inout [Int: CGRect],
                         truncated: inout Int) {
        // キーボードはキー1つ1つが Button として大量に写り込むため、サブツリーごと除外
        // (4Kトークン対策。入力は /type がキーイベント合成で行うので情報として不要)
        if node.elementType == .keyboard || node.elementType == .key { return }
        if shouldInclude(node, screen: screen) {
            if elements.count < BridgeAPI.maxSnapshotElements {
                let ref = elements.count + 1
                frames[ref] = node.frame
                elements.append(makeInfo(node, ref: ref, depth: depth))
            } else {
                truncated += 1
            }
        }
        for child in node.children {
            collect(child, depth: depth + 1, screen: screen,
                    elements: &elements, frames: &frames, truncated: &truncated)
        }
    }

    private func shouldInclude(_ node: XCUIElementSnapshot, screen: CGRect) -> Bool {
        let frame = node.frame
        guard frame.width >= 2, frame.height >= 2 else { return false }
        guard screen.isEmpty || frame.intersects(screen) else { return false }

        // 画面の大半を覆う Other コンテナは identifier があっても除外する。
        // タップ対象になり得ず、id が「タブ」等に見えると FM の誤タップを誘発する
        // (SwiftUI の .accessibilityIdentifier がコンテナに付くケース)。
        if node.elementType == .other {
            let screenArea = screen.width * screen.height
            if screenArea > 0, (frame.width * frame.height) / screenArea > 0.85 {
                return false
            }
        }

        let hasText = !node.identifier.isEmpty || !node.label.isEmpty || valueString(node) != nil

        switch node.elementType {
        // 操作可能な要素はテキストがなくても含める(アイコンだけのボタン等)
        case .button, .textField, .secureTextField, .textView, .`switch`, .toggle,
             .slider, .cell, .link, .searchField, .segmentedControl, .pickerWheel,
             .stepper, .datePicker, .checkBox, .menuItem:
            return true
        // 表示要素はテキストを持つ場合のみ
        case .staticText, .image:
            return hasText
        // 画面構造の手がかり
        case .navigationBar, .tabBar, .alert, .sheet:
            return true
        // その他(Other/Group/ScrollView 等)は identifier 付きのみ
        default:
            return !node.identifier.isEmpty
        }
    }

    private func makeInfo(_ node: XCUIElementSnapshot, ref: Int, depth: Int) -> ElementInfo {
        let frame = node.frame
        return ElementInfo(
            ref: ref,
            type: Self.typeName(node.elementType),
            identifier: node.identifier.isEmpty ? nil : node.identifier,
            label: node.label.isEmpty ? nil : node.label,
            value: valueString(node),
            placeholder: node.placeholderValue,
            enabled: node.isEnabled,
            frame: FTRect(x: frame.origin.x, y: frame.origin.y,
                          width: frame.width, height: frame.height),
            depth: depth)
    }

    private func valueString(_ node: XCUIElementSnapshot) -> String? {
        guard let value = node.value else { return nil }
        let string = (value as? String) ?? String(describing: value)
        return string.isEmpty ? nil : string
    }

    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .textView: return "TextView"
        case .`switch`: return "Switch"
        case .toggle: return "Toggle"
        case .slider: return "Slider"
        case .cell: return "Cell"
        case .link: return "Link"
        case .image: return "Image"
        case .icon: return "Icon"
        case .searchField: return "SearchField"
        case .segmentedControl: return "SegmentedControl"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .stepper: return "Stepper"
        case .datePicker: return "DatePicker"
        case .checkBox: return "CheckBox"
        case .menuItem: return "MenuItem"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .scrollView: return "ScrollView"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .window: return "Window"
        case .other: return "Other"
        default: return "Type\(type.rawValue)"
        }
    }

    // MARK: - Helpers

    private func requireApp() throws -> XCUIApplication {
        guard let app else {
            throw BridgeError(409, "セッションがありません。POST /session でアプリを起動してください")
        }
        return app
    }

    private func resolvePoint(ref: Int?, x: Double?, y: Double?) throws -> CGPoint {
        if let ref {
            guard let frame = refFrames[ref] else {
                throw BridgeError(404, "参照番号 [\(ref)] は未知です。先に GET /snapshot を実行してください")
            }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let x, let y {
            return CGPoint(x: x, y: y)
        }
        throw BridgeError(400, "ref または x/y が必要です")
    }

    private func coordinate(_ app: XCUIApplication, _ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: point.x, dy: point.y))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw BridgeError(400, "リクエストボディの JSON が不正です: \(error)")
        }
    }
}
