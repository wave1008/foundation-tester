// DispatchOrder.swift
// 複数機械にまたがる run が dispatch.lock を取る**順序**と、親が取ったロックを子へ引き渡す**印**。
//
// **なぜ順序が要るか**: 機械ごとの子が並列にそれぞれのロックを取りに行くと、
// 「A が機械①を取って②を待ち、B が②を取って①を待つ」形が作れる(循環待ち)。
// 待機列(RemoteDispatchQueue)は1台ぶんの前後関係しか決めないので、この形は FIFO でも残る。
// **全員が同じ全順序でしか取らない**なら循環は作れない —— これは原理的な排除であって、
// 待ち時間の短縮ではない。
//
// ssh 実行・プロセス起動はここに置かない(RemoteDispatchQueue / RemoteDispatchLock と同じ規律。
// 呼び出し側 = Sources/fleetest/DispatchPrelock.swift)。

import FTCore
import Foundation

/// 「機械をどの順で取るか」の**唯一の定義元**(純粋関数)。
public enum DispatchOrder {

    /// 順序付けの入力1件。`host` は facts キャッシュの鍵(ssh 宛先 / ホスト名)、
    /// `machine` はこの Mac の登録簿だけが知るローカルエイリアス
    /// (`--runner` に渡す表示名。**順序の鍵にはしない** —— 機械ごとに違いうる名前で
    /// 順序を決めると、別の Mac から見た順序と食い違って全順序が成り立たない)
    public struct Machine: Equatable, Sendable {
        public let machine: String
        public let host: String
        /// その Mac を一意に識別する値(`RemoteProbe.parseHardwareUUID` の正準形)。
        /// **nil = 不明**(facts キャッシュにも無く、順序を決める前の採取でも取れなかった ——
        /// 接続できないか、接続できても ioreg の1行が読めなかった機械)
        public let hardwareUUID: String?

        public init(machine: String, host: String, hardwareUUID: String?) {
            self.machine = machine
            self.host = host
            self.hardwareUUID = hardwareUUID
        }
    }

    /// ハードウェア UUID の昇順。**UUID を引けない機械は最後尾**へ回し、その中では host 昇順にする。
    ///
    /// **なぜ不明を既定値で埋めないか**: 埋めた値は「同じ機械なら誰が見ても同じ」を満たさないので、
    /// 別の Mac が同じ機械集合を別の位置に並べ、全順序が壊れる(= 循環待ちが戻る)。
    /// **なぜ1台の不明で順序付け全体を諦めないか**: 引ける機械どうしの相対順は正しいままで、
    /// そこに循環は作れない —— 全部をやめると、接続したことのある機械まで保護を失う。
    /// 不明どうしは host 昇順(決定的でありさえすればよい。この Mac だけが見る仮の順序で、
    /// 相手の Mac が別の順序を見ても、不明な機械を含む組では保護が無いこと自体は変わらない)。
    ///
    /// tie-break を host → machine まで下ろすのは**全順序にするため** —— 等しい要素が残ると
    /// 「同じ入力集合なら誰が呼んでも同じ並び」が Swift の非安定ソートで崩れうる
    public static func sorted(_ machines: [Machine]) -> [Machine] {
        machines.sorted { lhs, rhs in
            if (lhs.hardwareUUID == nil) != (rhs.hardwareUUID == nil) {
                return rhs.hardwareUUID == nil
            }
            if let left = lhs.hardwareUUID, let right = rhs.hardwareUUID, left != right {
                return left < right
            }
            if lhs.host != rhs.host { return lhs.host < rhs.host }
            return lhs.machine < rhs.machine
        }
    }
}

/// 親(fan-out)が取ったロックを子へ引き渡す印。**値は子がディスパッチする ssh 宛先**で、
/// 「握っている/いない」の真偽値にしない —— 環境変数は子孫へそのまま継がれるので、
/// 真偽値だと別の宛先へ向かう子まで取得を飛ばして**誰もロックを持たないまま走る**。
///
/// 印がある子は取得**と**解放の両方を飛ばす(片方だけだと、取っていないロックを解放して
/// 親のロックを消す / 二重解放になる)。**印が無ければ子は従来どおり自分で取る** ——
/// 単発 run(親が居ない)はこの縮退でそのまま動く。
public enum DispatchLockHandoff {

    /// 綴りは `FT_DISPATCH_TICKET`(`DispatchTicket.environmentKey`)の隣に置く
    public static let environmentKey = "FT_DISPATCH_LOCK_HELD"

    /// **手元(この Mac)を指す宛先**。ssh 宛先と同じ名前空間に置けるのは "local" が `--runner` の
    /// 予約語だから(`FTCore.MachineDispatch.isExplicitLocal` が常に「ここで走らせる」と読むので、
    /// リモートの宛先としては解決され得ない)。値は `DeviceMachineGrouping.localDisplayName` と同一。
    ///
    /// 2つの持ち主が同じ値を書く: ①手元の fan-out の親(`DispatchPrelock`)が local の子へ
    /// ②ディスパッチする側が ssh 越しに(`RemoteShell.remoteRunCommand`)—— **ランナー機の上で
    /// 走る `fleetest run --runner local` は、その機械のロックを既に発行側が握っている**ので、
    /// 自分で取りに行くと自分の親を待って詰む
    public static let localTarget = DeviceMachineGrouping.localDisplayName

    public static func environmentValue(sshTarget: String) -> String { sshTarget }

    /// この子の宛先のロックを親が握っているか。**宛先が一致したときだけ true**
    public static func isHeldByParent(environment: [String: String], sshTarget: String) -> Bool {
        guard let value = environment[environmentKey], !value.isEmpty else { return false }
        return value == sshTarget
    }
}
