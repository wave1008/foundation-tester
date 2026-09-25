// ApiMonitorEvents.swift
// `fleetest api monitor` が stdout へ流す NDJSON イベント型(monitorHold/monitorDevices/monitorLock/monitorRuns/monitorFrame)。ApiMonitorCommand.swift から分離。

import ArgumentParser
import CoreGraphics
import Foundation
import FTAndroid
import FTBridgeClient
import FTCore
import FTRemote
import ImageIO
import UniformTypeIdentifiers

// MARK: - JSON イベント

/// monitorDevices イベント: サイクル毎に1回、全デバイスの状態をまとめて出す
/// hold(`fleetest monitor pause`)の状態変化。拡張はこれで配信ヘルパーを畳む/戻す
/// (vscode-fleetest/src/monitorProcessManager.ts と同期)
struct ApiMonitorHoldEvent: Encodable {
    let kind = "monitorHold"
    let active: Bool
}

struct ApiMonitorDevicesEvent: Codable {
    private(set) var kind = "monitorDevices"
    let devices: [ApiMonitorDeviceInfo]
}

/// 機械の dispatch.lock の状態変化(docs/remote-runner.md §18.7 M2)。**手元でも出す** ——
/// ロックは機械に1本で、リモートへのディスパッチもローカル run も同じ1本を取る。
/// `machine` は **var** —— 子は自分の機械名を知らない(畳んだプロファイルでは "local")ので、
/// 中継する RemoteMonitorFanout が埋める(monitorDevices・monitorFrame と同じ規律)。
/// **欠落 = 手元**(monitorRuns / monitorDevices と同じ綴り。拡張は runBoardModel の
/// LOCAL_MACHINE_KEY へ写す)。
///
/// **ProtocolVersion は上げない**(「手元でも出す」変更): 欄は1つも増減せず型も
/// 変わらず、`machine` 欠落は fan-out の子が中継前に出していた既存の形そのまま。増えたのは
/// **この行が出てくる場所**だけで、欄の取りうる値も読み替えも足していない。
/// 同期相手: vscode-fleetest/src/monitorDeviceModel.ts(isMonitorEvent)
struct ApiMonitorLockEvent: Codable {
    private(set) var kind = "monitorLock"
    var machine: String?
    /// **その機械をまだ観測できているか**。子が落ちたら親が false で1行出す —— 古い占有を
    /// 出し続けないため(子の devices を捨てるのと同じ規律)。**false を「空き」と読ませない**:
    /// 拡張は控えを消して「不明」に戻す(破壊的操作の確認は不明を空きとして扱わない)
    let observed: Bool
    let held: Bool
    let issuer: String?
    let issuerHost: String?
    let acquiredAt: String?
    let mine: Bool

    init(occupancy: HostOccupancy, machine: String? = nil) {
        self.machine = machine
        self.observed = true
        self.held = occupancy.held
        self.issuer = occupancy.issuer
        self.issuerHost = occupancy.issuerHost
        self.acquiredAt = occupancy.acquiredAt
        self.mine = occupancy.mine
    }

    /// 「この機械はもう観測できていない」1行(親が子の死を見たときだけ出す)
    init(unobservedMachine machine: String) {
        self.machine = machine
        self.observed = false
        self.held = false
        self.issuer = nil
        self.issuerHost = nil
        self.acquiredAt = nil
        self.mine = false
    }
}

/// フリート横断の run 進捗(docs/design.md §18)。1レーン分。台帳(RunProgressLane)の
/// ISO8601 は運ばない —— 経過は monitor が自分の時計で秒に直す(18.3)
struct ApiMonitorRunProgressLane: Codable, Equatable {
    let key: String
    let name: String
    let platform: String?
    let scenario: String?
    let scenarioElapsedSeconds: Int?
    /// **記録用**(画面には出さない。ユーザー決定): 実行中シナリオの実績中央値(秒)。
    /// 台帳の値をそのまま運ぶ(作り替えない)
    let expectedSeconds: Int?
}

/// フリート横断の run 進捗。1 run 分(docs/design.md §18.2 の monitorRuns.runs[])
struct ApiMonitorRunProgress: Codable, Equatable {
    let pid: Int32
    let runID: String?
    let runGroup: String?
    let issuer: String?
    /// **issuer が nil のときは false**(不明を自分扱いにしない。HostOccupancy.mine と同じ向き)
    let mine: Bool
    let project: String
    let profile: String?
    let elapsedSeconds: Int
    let total: Int
    let done: Int
    let failed: Int
    /// **詰まりの事実**(docs/design.md §18.5 段6): 結果を捨てて振り直した累計。台帳の値をそのまま運ぶ
    let requeued: Int
    /// **詰まりの事実**: レーンが離脱した累計。台帳の値をそのまま運ぶ
    let laneDropouts: Int
    /// 残り見積もり(docs/design.md §18.4)。makespan の下界・実績ゼロの run は nil
    let etaSeconds: Int?
    let lanes: [ApiMonitorRunProgressLane]
    /// 台帳の値をそのまま運ぶ("building" / "preparing" / "running")。作り替えない。
    /// **版は揃える前提**(ProtocolVersion 16。欄を持たない版のランナーの行は decode できず
    /// 中継されない = align を促す既存の規律のまま)
    let phase: String
}

/// monitorRuns イベント: フリート横断の run 進捗(docs/design.md §18.2)。**手元でも出す**
/// (読む台帳が機械グローバルなので、CLI 実行の run も他人の run も載る)。`machine` は **var**
/// (子は畳んだプロファイルを見て自分を "local" と名乗るので、中継する RemoteMonitorFanout が
/// monitorLock/monitorDevices と同じ規律で埋める)
struct ApiMonitorRunsEvent: Codable, Equatable {
    private(set) var kind = "monitorRuns"
    var machine: String?
    /// **その機械をまだ観測できているか**。子が落ちたら親が false で1行出す(ApiMonitorLockEvent と
    /// 同じ規律。**false を「run 無し」と読ませない** —— 拡張は控えを消して「不明」に戻す)
    let observed: Bool
    let runs: [ApiMonitorRunProgress]

    init(runs: [ApiMonitorRunProgress], machine: String? = nil) {
        self.machine = machine
        self.observed = true
        self.runs = runs
    }

    /// 「この機械はもう観測できていない」1行(親が子の死を見たときだけ出す)
    init(unobservedMachine machine: String) {
        self.machine = machine
        self.observed = false
        self.runs = []
    }
}

/// fleetest api monitor の 1 デバイス分の状態。detail は補足が無ければ空文字列("")にする
/// (VSCode 拡張側(monitorModel.ts)の契約が detail: string 固定のため null は使わない。
/// ApiScenarioInfo 等の「省略可能フィールドは null を明示する」方針とは別)
struct ApiMonitorDeviceInfo: Codable {
    /// **var なのは RemoteMonitorFanout が書き戻すため**。子(ランナー)は畳んだプロファイルを
    /// 見るので自分の台を "local" と名乗り、id にホストが入らない。親が (host, name) の id へ
    /// 直してからタイルへ渡す(RemoteMonitorFanout.hostScoped)
    var id: String
    let name: String
    let platform: String
    let state: String
    let detail: String
    /// iOS の解決済みシミュレータ UDID(「デバイスモニター」タブの fleetest-simstream 画面ストリーミングに使う)。Android は nil。
    let udid: String?
    /// Android の adb serial(「デバイスモニター」タブの fleetest-androidstream 画面ストリーミングに使う)。iOS は nil。
    let serial: String?
    /// AndroidHealthProbe で確定した異常の識別子一覧。異常なし・非対象(iOS/実機/未接続)は nil
    let health: [String]?
    /// AndroidHealthProbe.detectRenderMode で検出した実描画モード("gpu"=host/Metal、"cpu"=swiftshader)。
    /// connected な Android のみ。iOS・実機・未検出は nil
    let renderMode: String?
    /// run-lease(RunLease.isFresh)が生存中なら true。fleetest api run がこのデバイスを使用中の意味。
    /// leaseStateDir 未解決時は常に false
    let inRun: Bool
    /// デバイスの実体種別("virtual" / "physical")。iOS 実機は fleetest-simstream が
    /// CoreSimulator 私有 API のため画面配信できない等、扱いが変わるので拡張側が分岐する
    let kind: String
    /// iOS ブリッジの宛先ホスト。シミュレータ・USB トンネルは "127.0.0.1"、LAN 経由の実機は
    /// その LAN IP。拡張が fleetest-devicepoll の --host に渡す。Android は nil
    let host: String?
    /// iOS ブリッジの実効ポート(connected のときのみ)。拡張が fleetest-devicepoll の --port に渡す。
    /// Android・未接続は nil(list-devices の port と同じ値)
    let port: UInt16?
    /// recording-lease(RecordingLease.isFresh)が生存中なら true。run profile の record:true で
    /// このデバイスの動画録画(VideoRecordingCoordinator)が進行中の意味。leaseStateDir 未解決時は常に false
    let recording: Bool
    /// 実行プロファイルに実在するか。false は determineStates(includeUnregistered:) が合成した
    /// 起動中デバイス(未登録)。追加フィールドのみで後方互換のため ProtocolVersion は不変
    /// (契約は vscode-fleetest/src/monitorDeviceModel.ts の MonitorDevice.registered)
    let registered: Bool
    /// **このデバイスが居る機械**(登録名。手元は nil)。`host` はブリッジ宛先の IP で別物 ——
    /// 名前が近いので取り違えない。モニターは手元のデバイスしか触れないため、リモートのタイルは
    /// 状態を観測できない。拡張はこの値でタイルにホスト名を出す
    /// (契約は vscode-fleetest/src/monitorDeviceModel.ts の MonitorDevice.machine)。
    /// 追加フィールドのみで後方互換のため ProtocolVersion は不変
    /// **var なのは id と同じ理由**(RemoteMonitorFanout が書き戻す)。子は畳んだプロファイルを
    /// 見るので自分の台を "local" と見なし、machine が nil になる —— 親が自分の知っている
    /// ホストラベルを入れないと、リモートのタイルからマシンのバッジが消える
    var machine: String?
    /// 画面が凍結している(一様フレームが2サイクル連続)。**この値は1サイクル遅れる** ——
    /// devices イベントはフレーム取得より前に出るため、判定に使うのは前サイクルの PNG。
    /// スクショを撮らないデバイス(未接続・タイルがストリーミング中で frame 抑止・
    /// ブリッジ不在)は最後の確定値を保つ(黙って false に戻すと凍結が画面から消える)。
    /// 契約は vscode-fleetest/src/monitorDeviceModel.ts の MonitorDevice.frozen
    let frozen: Bool
    /// iOS 実機の USB 接続か(devicectl の transportType == "wired")。仮想・Android・不明は nil。
    /// mergedDevices が WiFi 越しの分身の抑制に使う(拡張は読まない)。
    /// 追加フィールドのみで後方互換のため ProtocolVersion は不変
    let wired: Bool?
    /// **他の発行者・他のウィンドウがこの台の画面配信を張っている**(共有ランナーは
    /// FTCore.StreamLease、同じ Mac の別ウィンドウは FTCore.LocalStreamHolder)。
    /// 拡張はこの台の配信を起こさずポーリングのままにする —— 同じ台を人数ぶん捕捉すると
    /// ランナーが痛む(docs/remote-runner.md §18.2)。誰も張っていなければ false
    /// (どちらの判定もこの機械の中で完結するので「不明」は無い。nil は観測そのものを
    /// していない経路 = 合成デバイスの行だけ)。
    /// 追加フィールドのみで後方互換のため ProtocolVersion は不変
    /// (契約は vscode-fleetest/src/monitorDeviceModel.ts の MonitorDevice.streamedByOther)
    let streamedByOther: Bool?
    /// Android 実機のブリッジ(常駐 APK)が生きているか。**設定するのは
    /// `shouldProbeBridge` が true の台(Android 実機の connected)だけ** —— iOS の
    /// `state==="booted"`(ブリッジ無しの意味)と判定の出所が違う。Android の `state` は
    /// 「adb に見えるか」と「ブート完了か」しか表さず、ブリッジの有無とは無関係なので専用の欄にした。
    /// **観測できない(adb 失敗/timeout)ときは nil**(「不明」)—— false に丸めると、
    /// pidof がたまたま失敗しただけの回に絵が消える(誤って「ブリッジが無い」と断定する)。
    /// 追加フィールドのみで後方互換のため ProtocolVersion は不変
    /// (契約は vscode-fleetest/src/monitorDeviceModel.ts の MonitorDevice.bridgeRunning)
    let bridgeRunning: Bool?
}

/// monitorFrame イベント: state == connected のデバイスのみ、スクリーンショットを添えて出す
struct ApiMonitorFrameEvent: Encodable {
    let kind = "monitorFrame"
    let device: String
    let jpegBase64: String
    let width: Int
    let height: Int
}
