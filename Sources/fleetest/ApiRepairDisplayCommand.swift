// エミュレータの表示凍結(blank)を sleep/wake で修復する(fleetest api repair-display)。
// 拡張(monitorHealthWatchdog)の自動修復から呼ばれる唯一の窓口で、gRPC 優先・adb フォールバック・
// blank 判定はすべて AndroidHealthProbe に閉じる(拡張側で gRPC を話さない = proto と
// 判定閾値を二重に持たない)。
// 対向: vscode-fleetest/src/adbWifiRepair.ts の repairDisplay。

import ArgumentParser
import Foundation
import FTAndroid

struct ApiRepairDisplayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair-display",
        abstract: "Recover a frozen emulator display with sleep/wake and print the result as JSON on stdout")

    @Option(help: "adb serial of the target device (e.g. emulator-5554)")
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

/// 対向: vscode-fleetest/src/adbWifiRepair.ts(repaired だけを見る)
private struct ApiRepairDisplayOutput: Encodable {
    let kind = "repairDisplay"
    let serial: String
    let repaired: Bool
}
