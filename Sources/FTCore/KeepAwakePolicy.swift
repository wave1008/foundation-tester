// 実機の自動ロックを run 中だけ抑える機能の on/off。**唯一の定義元**。
//
// 効かせ方は OS で別:
//   - iOS  = 常駐ランナーが自分で起こす(Runner/FleetestRunnerUITests/KeepAwake.swift)。
//            ホストは環境変数を xctestrun へ渡すだけ(BridgeLauncher.injectPort)
//   - Android = `svc power stayon true`(AndroidPhysicalDevice.prepareForRun)
//
// 既定は on。off にすると **iOS はパルスを撃たなくなり、Android は stayon を戻す**
// (stayon は端末に永続する副作用なので、off にした人が「消灯しない端末」を抱えたままに
// ならないよう明示的に false を撃つ)。
//
// VSCode 拡張の設定タブ「実機」→「実機画面の自動ロックを抑制する」がこの環境変数を
// 立てる(off のときだけ `FT_KEEP_AWAKE=0`)。同期相手: vscode-fleetest/src/spawnEnv.ts

import Foundation

public enum KeepAwakePolicy {

    /// 抑止そのものの on/off。**`"0"` だけが off**(未設定・空・その他は on = 既定を壊さない)
    public static let envKey = "FT_KEEP_AWAKE"

    /// iOS のパルスの玉(home|volume)。ランナーだけが読む
    public static let pulseEnvKey = "FT_KEEP_AWAKE_PULSE"

    /// ホストからランナー(xctestrun)へ渡す環境変数。**ランナーが読む鍵はここに全部載せる**
    /// (`KeepAwakeInputPathsTests.testEveryKeepAwakeEnvKeyIsForwarded` が漏れを検出)
    public static let forwardedEnvKeys = [envKey, pulseEnvKey]

    public static var suppressesAutoLock: Bool {
        ProcessInfo.processInfo.environment[envKey] != "0"
    }
}
