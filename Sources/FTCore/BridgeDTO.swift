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
    public static let bridgeProtocolVersion = 2
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
    /// xcuitest ランナーが高速入力(quiescence スキップ)swizzle の導入に成功したか(FastInput.swift)。
    /// 旧ランナー・他ブリッジは返さない → nil 許容(=非対応)
    public var fastInputAvailable: Bool?
    /// このブリッジが**この対象アプリでは実行できない**アクション名(FlowStep.action と同じ語:
    /// "swipe" / "press" 等)。ホストはこれを見て代替ドライバへ回す/明示的に失敗させる。
    /// 「compose なら swipe 不可」のような知識をホストへ散らかさず、事情を知っている
    /// ブリッジ側に集約するための申告。返さない実装は nil(=制約なしとみなす)。
    public var unsupportedActions: [String]?

    public init(ready: Bool, device: String, osVersion: String, sessionBundleID: String?,
                engine: String? = nil, protocolVersion: Int? = nil, applicationState: String? = nil,
                uiFramework: String? = nil, bridgeVersionCode: Int? = nil,
                fastInputAvailable: Bool? = nil, unsupportedActions: [String]? = nil) {
        self.ready = ready
        self.device = device
        self.osVersion = osVersion
        self.sessionBundleID = sessionBundleID
        self.engine = engine
        self.protocolVersion = protocolVersion
        self.applicationState = applicationState
        self.uiFramework = uiFramework
        self.bridgeVersionCode = bridgeVersionCode
        self.fastInputAvailable = fastInputAvailable
        self.unsupportedActions = unsupportedActions
    }
}

public struct LaunchRequest: Codable {
    public var bundleID: String
    /// true なら XCUIApplication.activate()(起動中は状態保持で前面化、未起動なら起動)。
    /// nil/false は従来どおり launch(再起動)。旧ランナーは本フィールドを無視して launch する。
    public var activate: Bool?
    /// true ならプロキシ接続のみ(XCUIApplication を生成・保持するだけで launch/activate を呼ばない。
    /// simctl で起動済みのアプリに使う=FastLaunchDriver)。activate より優先。
    /// 旧ランナーは無視して launch する(TapRequest.fast と同じ互換方針で版は据え置き)
    public var attachOnly: Bool?
    public init(bundleID: String, activate: Bool? = nil, attachOnly: Bool? = nil) {
        self.bundleID = bundleID
        self.activate = activate
        self.attachOnly = attachOnly
    }
}

/// アクセシビリティツリーの1要素(ランナー側でフィルタ済み)
public struct ElementInfo: Codable, Sendable {
    /// set-of-mark 参照番号(スナップショット毎に振り直す)
    public var ref: Int
    /// 型名。**ホスト側では常に先頭小文字**(`button` / `staticText`)。
    /// ブリッジは歴史的経緯で `Button` を送ってくるので、デコード時に normalizedType で畳む。
    /// セレクタ記法 `.button` と、スナップショット表示・生成コードの型名を一致させるための唯一の変換点
    /// (3ブリッジの wire 形式は変えない = APK versionCode もプロトコル版も上げなくてよい)。
    public var type: String
    public var identifier: String?
    public var label: String?
    public var value: String?
    public var placeholder: String?
    public var enabled: Bool
    /// チェック状態(true のときだけ送る = 省略は「オフ、または状態を持たない要素」)。
    /// 取得元は iOS=`isSelected`(Compose iOS は Switch の value を出さないためこちらが唯一の経路)/
    /// Android=`AccessibilityNodeInfo.isChecked`。isChecked / isNotChecked が唯一の読み手
    public var checked: Bool?
    public var frame: FTRect
    public var depth: Int

    public init(ref: Int, type: String, identifier: String?, label: String?, value: String?,
                placeholder: String?, enabled: Bool, frame: FTRect, depth: Int,
                checked: Bool? = nil) {
        self.ref = ref
        self.type = Self.normalizedType(type)
        self.identifier = identifier
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.enabled = enabled
        self.checked = checked
        self.frame = frame
        self.depth = depth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(Int.self, forKey: .ref)
        type = Self.normalizedType(try container.decode(String.self, forKey: .type))
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        checked = try container.decodeIfPresent(Bool.self, forKey: .checked)
        frame = try container.decode(FTRect.self, forKey: .frame)
        depth = try container.decode(Int.self, forKey: .depth)
    }

    /// 先頭 1 文字だけ小文字化する(`StaticText` → `staticText`)。冪等なので二重適用しても安全
    public static func normalizedType(_ type: String) -> String {
        guard let first = type.first, first.isUppercase else { return type }
        return first.lowercased() + type.dropFirst()
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
    /// true = quiescence 待ちスキップの高速入力(PoC・FastInput.swift)。省略可能な追加
    /// フィールドのみのため bridgeProtocolVersion は据え置き(旧ランナーは無視して通常タップ・
    /// 旧ホストは未指定。bump すると稼働中の旧ホスト常駐プロセスが新ランナーを stale 判定して
    /// 再起動ループに入るため、追加フィールドでは上げない)
    public var fast: Bool?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, fast: Bool? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
        self.fast = fast
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

/// **ジェスチャの向き**(指の動き)。ブリッジの /swipe はこれを受ける
public enum FTSwipeDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

/// **スクロールの向き**(コンテンツ基準。標準用語どおり `.down` = 下に読み進める)。
/// Shirates の `ScrollDirection` と同じ構成(`None` は ftester では Optional が担うため持たない)。
/// **指の動きとは逆**なので、ジェスチャへの写像はここに1箇所だけ置く
public enum FTScrollDirection: String, Codable, CaseIterable, Sendable {
    case down, up, right, left

    /// このスクロールを起こすための指の動き(`.down` に読み進めるには指を上へ動かす)
    public var swipe: FTSwipeDirection {
        switch self {
        case .down: return .up
        case .up: return .down
        case .right: return .left
        case .left: return .right
        }
    }
}

public struct SwipeRequest: Codable {
    public var direction: FTSwipeDirection
    /// TapRequest.fast と同じ(互換性の注記もそちらを参照)
    public var fast: Bool?
    public init(direction: FTSwipeDirection, fast: Bool? = nil) {
        self.direction = direction
        self.fast = fast
    }
}

public struct PressRequest: Codable {
    public var ref: Int?
    public var x: Double?
    public var y: Double?
    public var duration: Double
    /// TapRequest.fast と同じ(互換性の注記もそちらを参照)
    public var fast: Bool?
    public init(ref: Int? = nil, x: Double? = nil, y: Double? = nil, duration: Double,
                fast: Bool? = nil) {
        self.ref = ref
        self.x = x
        self.y = y
        self.duration = duration
        self.fast = fast
    }
}

public struct OKResponse: Codable {
    public var ok: Bool
    /// 通常と違う経路を通ったときの短い説明(既定 nil)。失敗ではなく観測用(例: InAppBridge.handleTap の
    /// activate 不発→合成タッチ)。throw にしない代わりに StepExecutor.driverFallback へ載せて可視化する。
    public var note: String?
    public init(ok: Bool = true, note: String? = nil) {
        self.ok = ok
        self.note = note
    }
}

public struct ErrorResponse: Codable {
    public var error: String
    public init(error: String) { self.error = error }
}
