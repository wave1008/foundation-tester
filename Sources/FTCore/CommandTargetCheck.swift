// dry-run が通ったステップのコマンド名を、実行プロファイルのデバイスと照合する(`DSLCommandIndex.unsupportedTargets`)。
// 判定だけを持つ。文言は呼び手(`fleetest run --dry-run` / `fleetest api run --dry-run`)が持つ。
// 入力の `command` はステップのイベントの欄をそのまま使う(description から切り出さない)。

import Foundation

public enum CommandTargetCheck {

    /// 照合に使うデバイスの事実
    public struct Device: Sendable, Equatable {
        public let name: String
        public let platform: String
        public let physical: Bool

        public init(name: String, platform: String, physical: Bool) {
            self.name = name
            self.platform = platform
            self.physical = physical
        }

        public init(_ device: ResolvedDevice) {
            self.init(name: device.name, platform: device.platform, physical: device.spec.isPhysical)
        }

        /// このデバイスが当てはまる実行先
        public var targets: Set<CommandUnsupportedTarget> {
            guard platform == "ios" else { return [] }
            var result: Set<CommandUnsupportedTarget> = []
            if physical { result.insert(.iosPhysical) }
            return result
        }
    }

    public struct Step: Sendable, Equatable, Hashable {
        public let command: String
        public let file: String?
        public let line: Int?

        public init(command: String, file: String?, line: Int?) {
            self.command = command
            self.file = file
            self.line = line
        }
    }

    public struct Finding: Sendable, Equatable {
        public let step: Step
        public let device: String
        public let target: CommandUnsupportedTarget

        public init(step: Step, device: String, target: CommandUnsupportedTarget) {
            self.step = step
            self.device = device
            self.target = target
        }
    }

    /// `platform` で走るシナリオのステップが、そのシナリオを受け持ちうるデバイス(同じ platform の全台)の
    /// どれかで動かないものを返す。並びはステップ順 → デバイス順。同じ (コマンド, 位置) は1回だけ数える
    /// (ループで同じ行を何度通っても1件)
    public static func findings(steps: [Step], platform: String, devices: [Device]) -> [Finding] {
        let candidates = devices.filter { $0.platform == platform }
        var seen = Set<Step>()
        var result: [Finding] = []
        for step in steps where seen.insert(step).inserted {
            guard let unsupported = DSLCommandIndex.unsupportedTargets[step.command] else { continue }
            for device in candidates {
                for target in device.targets.intersection(unsupported).sorted() {
                    result.append(Finding(step: step, device: device.name, target: target))
                }
            }
        }
        return result
    }
}
