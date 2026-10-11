// シミュレータの SpringBoard を起こし直す。**前面のアプリと XCUITest ランナーも一緒に落ちる**(実測: マップのプロセスが消え、
// ランナーの /status が答えなくなった)ので、呼び手はランナーを作り直し、アプリを起動し直す時点でだけ撃つ。
// 呼び手は2つ: 残ったシステムアラートの3段目(`ProfileWorkerFactory.respringAndRebuild`)と、劣化したランナーの回復
// (`BridgeProvisioner.restartRunner`)。SpringBoard の劣化(`/systemalert` の1問が 3.5s 前後)はランナーの起動し直しでは
// 直らず、SpringBoard の起こし直しで 0.11〜0.18s に戻った(実測・起こし直し約 8s)

import Foundation

public enum SimulatorSpringBoard {

    /// 撃つコマンド(テストが形を固定する)。`system/` は非推奨の警告を出すが動く(exit 0。実測)
    public static func command(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "launchctl", "kickstart", "-k", "system/com.apple.SpringBoard"]
    }

    /// 起こし直す。**終了コードで成否を返す**(Shell.run は非ゼロで投げない)。detail は失敗の末尾
    public static func restart(udid: String) -> (ok: Bool, detail: String) {
        guard let result = try? Shell.run(command(udid: udid), timeout: 30) else {
            return (false, "simctl did not run")
        }
        return (result.status == 0, result.tail)
    }
}
