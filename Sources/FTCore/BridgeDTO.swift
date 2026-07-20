// BridgeDTO.swift
// ホスト(macOS CLI)とXCUITestランナー(iOSシミュレータ)の間で共有するAPI型。
// このファイルは Runner/FTesterRunnerUITests ターゲットにも直接コンパイルされるため、
// Foundation 以外に依存してはならない。

import Foundation

public enum BridgeAPI {
    public static let defaultPort: UInt16 = 8123
    /// 1回のスナップショットで返す要素数の上限(4Kトークン対策の第一段)
    public static let maxSnapshotElements = 120
    /// ブリッジ HTTP API のプロトコルバージョン。エンドポイントやリクエスト/レスポンスの形を
    /// 変えたら必ず +1 する。/status で返され、旧ビルドのランナーの自動再起動判定に使う
    /// (nil = この定数導入前のビルド = 旧版扱い)。
    public static let bridgeProtocolVersion = 1
}

/// CGRect の代わりに使うプラットフォーム非依存の矩形(エンコード形式を固定する)
public struct FTRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

public struct StatusResponse: Codable, Sendable {
    public var ready: Bool
    public var device: String
    public var osVersion: String
    public var sessionBundleID: String?
    /// 駆動エンジン種別("inapp" / "xcuitest")。同一シミュレータ(UDID)に複数ブリッジが
    /// 共存するハイブリッド時、ホストがどのブリッジかを /status で区別するために使う。
    /// 旧ブリッジは返さない → decodeIfPresent で nil 許容(=不明)。
    public var engine: String?
    /// BridgeAPI.bridgeProtocolVersion。旧ブリッジは返さない → nil 許容(=旧版扱い)。
    public var protocolVersion: Int?
    /// UIApplication.applicationState の文字列化("active"/"inactive"/"background")。
    /// inapp 専用診断(背面 suspend でハングしていないかの申告)。xcuitest ブリッジは返さない → nil 許容。
    public var applicationState: String?
    /// inapp ブリッジが自己申告する UI フレームワーク("compose"/"uikit")。判定は InAppBridge の
    /// compose-resources 実在チェック。xcuitest/Android ブリッジは返さない → nil 許容。
    public var uiFramework: String?
    /// Android ブリッジ APK の versionCode(BridgeRouter.java handleStatus)。稼働中の旧ブリッジを
    /// probe 時に検知して自動更新するために使う。iOS ブリッジ・旧 Android ブリッジは返さない → nil 許容。
    public var bridgeVersionCode: Int?

    public init(ready: Bool, device: String, osVersion: String, sessionBundleID: String?,
                engine: String? = nil, protocolVersion: Int? = nil, applicationState: String? = nil,
                uiFramework: String? = nil, bridgeVersionCode: Int? = nil) {
        self.ready = ready
        self.device = device
        self.osVersion = osVersion
        self.sessionBundleID = sessionBundleID
        self.engine = engine
        self.protocolVersion = protocolVersion
        self.applicationState = applicationState
        self.uiFramework = uiFramework
        self.bridgeVersionCode = bridgeVersionCode
    }
}

public struct LaunchRequest: Codable {
    public var bundleID: String
    /// true なら XCUIApplication.activate()(起動中は状態保持で前面化、未起動なら起動)。
    /// nil/false は従来どおり launch(再起動)。旧ランナーは本フィールドを無視して launch する。
    public var activate: Bool?
    public init(bundleID: String, activate: Bool? = nil) {
        self.bundleID = bundleID
        self.activate = activate
    }
}

/// アクセシビリティツリーの1要素(ランナー側でフィルタ済み)
public struct ElementInfo: Codable, Sendable {
    /// set-of-mark 参照番号(スナップショット毎に振り直す)
    public var ref: Int
    public var type: String
    public var identifier: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var enabled: Bool
    public var frame: FTRect
    public var depth: Int

    public init(ref: Int, type: String, identifier: String?, label: String?, value: String?,
                placeholder: String?, enabled: Bool, frame: FTRect, depth: Int) {
        self.ref = ref
        self.type = type
        self.identifier = identifier
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.frame = frame
        self.depth = depth
    }
}

public struct SnapshotResponse: Codable, Sendable {
    public var sessionBundleID: String?
    public var screen: FTRect
    public var elements: [ElementInfo]
    /// 上限超過で切り捨てた要素数(FMへのプロンプトにも明記する)
    public var truncatedCount: Int

    public init(sessionBundleID: String?, screen: FTRect, elements: [ElementInfo], truncatedCount: Int) {
        self.sessionBundleID = sessionBundleID
        self.screen = screen
        self.elements = elements
        self.truncatedCount = truncatedCount
    }
}

public struct TapRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
    }
}

public struct DragRequest: Codable {
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    /// 押下から移動開始までの静止時間(秒)。nil は最小値(0.05)扱い
    public var press: Double?
    /// 移動開始から離すまでの時間(秒)。nil は既定速度
    public var duration: Double?
    public init(fromX: Double, fromY: Double, toX: Double, toY: Double,
                press: Double? = nil, duration: Double? = nil) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.press = press
        self.duration = duration
    }
}

public struct TypeRequest: Codable {
    public var ref: Int?
    public var text: String
    public init(ref: Int? = nil, text: String) {
        self.ref = ref
        self.text = text
    }
}

public enum FTSwipeDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

public struct SwipeRequest: Codable {
    public var direction: FTSwipeDirection
    public init(direction: FTSwipeDirection) { self.direction = direction }
}

public struct PressRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    public var duration: Double
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, duration: Double) {
        self.ref = ref
        self.x = x
        self.y = y
        self.duration = duration
    }
}

public struct OKResponse: Codable {
    public var ok: Bool
    public init(ok: Bool = true) { self.ok = ok }
}

public struct ErrorResponse: Codable {
    public var error: String
    public init(error: String) { self.error = error }
}
