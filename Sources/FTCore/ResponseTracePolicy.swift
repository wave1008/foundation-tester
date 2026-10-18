// iOS 実機のレスポンス計測で xctrace の記録を録るかの判定と、xctrace の引数。純粋関数。
// 呼び手は `fleetest run --profile` と `fleetest api run` の両方(fleetest/ResponseTraceSession.swift が1箇所で受ける)。

import Foundation

public enum ResponseTracePolicy {

    /// 記録の対象デバイス。計測モードで、有効なデバイスが iOS 実機 1 台のときだけ(Android は最初のフレームをブリッジが返す)。
    /// `udid` は実行プロファイルの記載そのまま(devicectl の識別子のことがある)。`xctrace --device` へ渡す前の解決は呼び手
    public static func recordingDevice(resolved: ResolvedProfile) -> DeviceSpec? {
        guard resolved.responseMeasurement, resolved.devices.count == 1, let device = resolved.devices.first,
              device.platform == "ios", device.spec.isPhysical,
              let udid = device.spec.udid, !udid.isEmpty else { return nil }
        return device.spec
    }

    /// 記録の上限。xctrace が止められずに残ったときの安全弁(`--time-limit`)。
    /// 根拠: ディスクは 約 3 MB/秒(iPhone SE3 の実測。docs/response-measurement.md §8.5)なので 2 時間 ≒ 21 GB。
    /// これを超えて走った run は、範囲の外の注入が空のまま残る(`ResponseTracePatch.apply` の outside)
    public static let recordTimeLimit = "2h"

    /// SIGINT から記録が保存されて終わるまでの上限(秒)の下限。保存の所要は記録の長さに比例するが比例係数は未測定なので、
    /// 記録 1 秒あたり `stopSecondsPerRecordedSecond` を足す。尽きたら SIGKILL して「保存が終わらなかった」と言う
    public static let stopBaseSeconds = 60.0
    public static let stopSecondsPerRecordedSecond = 0.25
    public static func stopLimitSeconds(recordedSeconds: Double) -> Double {
        stopBaseSeconds + max(recordedSeconds, 0) * stopSecondsPerRecordedSecond
    }

    /// 書き出し(`xctrace export`)1回の上限(秒)。未測定の安全弁(試作の 9 秒の記録の 1 表は秒単位だった)。
    /// 尽きたら書き出しの失敗として言う
    public static let exportTimeoutSeconds = 300.0

    /// 録り始めを待つ上限(秒)。xctrace は起動の直後に最初の出力を出す(試作で観測)ので、出力が出るか終了するまで待つ。
    /// 尽きても失敗にはしない: 記録が覆わない注入には何も入れない(`ResponseTracePatch.Coverage`)ので、遅れた開始は欠けとして現れる
    public static let startConfirmSeconds = 30.0

    /// 開始の試行の回数。根拠: `--attach backboardd` の名前の照合が、同じ端末・同じ条件で手で3回打って1回
    /// 「Cannot find process matching name」(終了コード 19)で失敗した(iPhone SE3)。その失敗のときだけ 1 秒おいて起こし直す
    public static let startAttempts = 3
    public static let targetNotFoundMessage = "Cannot find process matching name"
    /// xctrace が録り始めたときに出す行(実機の出力で確認)
    public static let recordingStartedMarker = "Ctrl-C to stop the recording"

    public static let displayedSurfacesSchema = "displayed-surfaces-interval"
    public static let timeInfoSchema = "time-info"

    /// 計測器は Display だけ・記録の対象は名前で `backboardd`(`--attach`)。根拠(iPhone SE3・iOS 26.6.2 で実測):
    /// `--all-processes` だと、記録中にアプリを1回起動しただけで SIGINT からの保存が 72 秒(Display だけ)〜124 秒(Hangs も)かかり、
    /// 停止の上限で殺された。対象を1つのプロセスに絞ると同じ条件で 5〜7 秒。画面に出たフレーム(displayed-surfaces-interval)は
    /// 端末全体の表なので、対象を絞っても起動したアプリのフレームまで入る。SpringBoard を pid で指定する形は、`devicectl` の一覧が
    /// 起動し直した後の古い pid を返して開始に失敗したので採らない(backboardd は名前で指定でき、起動し直しも無い)。
    /// Hangs の表はこの機能では使わないので録らない
    public static func recordArguments(udid: String, output: String) -> [String] {
        ["xcrun", "xctrace", "record", "--device", udid, "--instrument", "Display", "--attach", "backboardd",
         "--time-limit", recordTimeLimit, "--output", output]
    }

    public static func exportTableArguments(trace: String, schema: String, output: String) -> [String] {
        ["xcrun", "xctrace", "export", "--input", trace,
         "--xpath", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"\(schema)\"]", "--output", output]
    }

    public static func exportTocArguments(trace: String, output: String) -> [String] {
        ["xcrun", "xctrace", "export", "--input", trace, "--toc", "--output", output]
    }

    /// 一時フォルダの名前。残骸の掃除はこの接頭辞で探す
    public static let workDirPrefix = "fleetest-resp-trace-"

    /// 持ち主(run のプロセス)の pid を書くファイル名。残骸の判定に使う
    public static let ownerFileName = "owner.pid"
    /// 持ち主の書き出しがまだ無いフォルダを残骸と見なす経過秒。作った直後(pid を書く前)の一瞬を消さないための余裕
    public static let ownerlessGraceSeconds = 60.0

    /// 前の run が殺されて残した一時フォルダか。持ち主が分かるなら生死で、分からなければ作ってからの経過で決める
    public static func isStale(name: String, ownerPID: Int32?, ownerAlive: Bool, ageSeconds: Double) -> Bool {
        guard name.hasPrefix(workDirPrefix) else { return false }
        if ownerPID != nil { return !ownerAlive }
        return ageSeconds > ownerlessGraceSeconds
    }
}
