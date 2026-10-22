// dry-run の「このデバイスでは動かないコマンド」の警告文(判定は FTCore.CommandTargetCheck)。
// `fleetest run --dry-run --profile` と `fleetest api run --dry-run --profile` が同じ文を出す。
// 警告に留める(dry-run の合否は変えない)。

import FTCore
import Foundation

enum DryRunTargetWarnings {

    static func step(from event: ScenarioEvent) -> CommandTargetCheck.Step? {
        guard event.kind == "step", let command = event.command else { return nil }
        return CommandTargetCheck.Step(command: command, file: event.file, line: event.line)
    }

    /// 同じステップ・同じ理由のデバイスは1行にまとめる
    static func lines(scenarioID: String, findings: [CommandTargetCheck.Finding]) -> [String] {
        struct Key: Hashable {
            let step: CommandTargetCheck.Step
            let target: CommandUnsupportedTarget
        }
        var order: [Key] = []
        var devices: [Key: [String]] = [:]
        for finding in findings {
            let key = Key(step: finding.step, target: finding.target)
            if devices[key] == nil { order.append(key) }
            devices[key, default: []].append("\"\(finding.device)\"")
        }
        return order.map { key in
            let names = devices[key] ?? []
            var location = ""
            if let file = key.step.file {
                location = " at \(URL(fileURLWithPath: file).lastPathComponent)"
                    + (key.step.line.map { ":\($0)" } ?? "")
            }
            return "⚠️ \(scenarioID): \(key.step.command)\(location) cannot run on"
                + " \(names.count == 1 ? "device" : "devices") \(names.joined(separator: ", "))"
                + " — \(reason(key.target))"
        }
    }

    static func reason(_ target: CommandUnsupportedTarget) -> String {
        switch target {
        case .iosPhysical:
            return "it is a physical iPhone, which this command cannot drive"
        }
    }
}
