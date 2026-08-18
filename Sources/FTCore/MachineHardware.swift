// MachineHardware.swift
// この機械の CPU 情報。記録(RemoteHostFacts)と、実績が無い機械の事前係数(FleetSplit)の
// 基準に使う。取得は macOS の sysctl/ProcessInfo に閉じる(呼び出し側はプラットフォーム分岐を
// 持たない)。

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// この機械の CPU 情報。記録(RemoteHostFacts)と、実績が無い機械の事前係数の基準に使う
public struct MachineHardware: Codable, Equatable, Sendable {
    /// 例 "Apple M2 Ultra"(sysctl machdep.cpu.brand_string)
    public let processorModel: String
    /// 論理コア数(ProcessInfo.processInfo.activeProcessorCount)
    public let coreCount: Int

    public init(processorModel: String, coreCount: Int) {
        self.processorModel = processorModel
        self.coreCount = coreCount
    }

    /// 取れなければ processorModel は "unknown"(coreCount は ProcessInfo が必ず 1 以上を返す)
    public static func current() -> MachineHardware {
        MachineHardware(processorModel: currentProcessorModel(),
                        coreCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    private static func currentProcessorModel() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return "unknown"
        #endif
    }
}
