// エミュレータの表示凍結(blank)を sleep/wake で修復する(ftester api repair-display)。
// 拡張(monitorHealthWatchdog)の自動修復から呼ばれる唯一の窓口で、gRPC 優先・adb フォールバック・
// blank 判定はすべて AndroidHealthProbe に閉じる(拡張側で gRPC を話さない。以前は
// vscode-ftester/src/emulatorGrpc.ts に同じ手順の第二実装があり proto と判定閾値の二重管理だった)。
// 対向: vscode-ftester/src/adbWifiRepair.ts の repairDisplay。

import ArgumentParser
import Foundation
import FTAndroid

struct ApiRepairDisplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair-display",
        abstract: "エミュレータの表示凍結を sleep/wake で修復し結果を JSON で stdout に出力する")

    @Option(help: "対象デバイスの adb serial(例 emulator-5554)")
    var serial: String

    func run() async throws {
        // 最大2サイクル(dwell 1.5s→3.0s)で成功時 ~4s・抵抗変種 ~11s。呼び出し側のタイムアウトは
        // これより十分長く取ること(adbWifiRepair.ts の REPAIR_TIMEOUT_MS)
        let repaired = await AndroidHealthProbe.repairBlankDisplay(serial: serial)
        let output = ApiRepairDisplayOutput(serial: serial, repaired: repaired)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        print(String(data: data, encoding: .utf8)!)
    }
}

/// 対向: vscode-ftester/src/adbWifiRepair.ts(repaired だけを見る)
private struct ApiRepairDisplayOutput: Encodable {
    let kind = "repairDisplay"
    let serial: String
    let repaired: Bool
}
