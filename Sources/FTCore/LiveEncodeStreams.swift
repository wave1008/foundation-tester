// この Mac でホストのハードウェア動画エンコーダを使っている配信(ライブ更新)の有無。
// 録画のクリップの切り出し(VideoRecordingCoordinator.extractAtRunEnd)が「ハードウェアに余力があるか」を
// 確かめる合図にだけ使う。対象は iOS Simulator の h264 配信(fleetest-simstream --codec h264 = VTCompressionSession を
// 1台1本張る)。Android の配信は端末側で符号化する(screenrecord)のでホストのエンコーダを使わない。
// 起こし方の契約: vscode-fleetest/src/monitorDeviceStreamController.ts・monitorLiveController.ts の codecArgs

import Foundation

enum LiveEncodeStreams {
    /// `ps` を読む。読めなければ false(= 配信は無いとみなしてハードウェアで撃つ。遅ければ期限と失敗の扱いが拾う)
    static func anyActive() -> Bool {
        guard let result = try? Shell.run(["ps", "-ww", "-axo", "command="], timeout: 10),
              result.status == 0 else { return false }
        return count(psOutput: result.output) > 0
    }

    /// 純粋関数: `ps -o command=` の出力から h264 の Simulator 配信の本数
    static func count(psOutput: String) -> Int {
        psOutput.split(separator: "\n").filter { line in
            let tokens = line.split(separator: " ").map(String.init)
            guard let program = tokens.first,
                  URL(fileURLWithPath: program).lastPathComponent == "fleetest-simstream",
                  let codec = tokens.firstIndex(of: "--codec"), codec + 1 < tokens.count else { return false }
            return tokens[codec + 1] == "h264"
        }.count
    }
}
