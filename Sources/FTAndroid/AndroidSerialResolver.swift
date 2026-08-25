// serial を渡さない対話コマンド(MCP の ft_*)向けのデバイス選択。
//
// **serial 無しで adb を撃たない**: `-s` を付けない adb は複数台接続時に
// "more than one device/emulator" で落ち、生のエラーがそのまま利用者へ出る
// (2026-08-06 の外部フィードバック #5)。run プロファイル経由なら
// AndroidDeviceCatalog.resolveSerial が解決するが、profile 無しの探索には解決口が無かった。
//
// 方針は iOS の BridgeDiscovery と同じ: **1台だけなら自動採用**・複数なら AVD 名付きで
// 列挙してエラー・0台なら起動方法を返す。

import FTCore
import Foundation

public enum AndroidSerialResolver {

    /// 接続中の1台。avd は起動中エミュレータのみ(実機は nil)
    public struct Device: Sendable, Equatable {
        public let serial: String
        public let avd: String?

        public init(serial: String, avd: String?) {
            self.serial = serial
            self.avd = avd
        }

        public var label: String { avd.map { "\(serial) (\($0))" } ?? serial }
    }

    public enum Decision: Equatable {
        case use(String)
        case none
        /// 複数 = 利用者に選ばせる
        case ambiguous([Device])
    }

    /// 判断だけ(IO 無し)。explicit があれば常にそれ。
    /// ambiguous は serial だけを持つ(表示名は呼び出し側が describe で足す)
    public static func decide(explicit: String?, connected: [String]) -> Decision {
        if let explicit, !explicit.isEmpty { return .use(explicit) }
        let sorted = connected.sorted()
        switch sorted.count {
        case 0: return .none
        case 1: return .use(sorted[0])
        default: return .ambiguous(sorted.map { Device(serial: $0, avd: nil) })
        }
    }

    /// 接続中の serial(AVD 名は引かない = adb 往復を増やさない)
    public static func connectedSerials() -> [String] {
        (try? AndroidDeviceCatalog.connectedSerials()) ?? []
    }

    /// **列挙して見せるときだけ** AVD 名を引く(serial だけでは利用者がどれか分からないため)。
    /// 名前の取得はエミュレータ1台ごとに adb 往復するので、1台に決まる経路では呼ばない
    public static func describe(serials: [String]) -> [Device] {
        let avds = (try? AndroidDeviceCatalog.runningAVDs()) ?? [:]
        return serials.map { Device(serial: $0, avd: avds[$0]) }
    }

    // MARK: - 文言(1箇所に置く)

    public static func adoptedNote(_ device: Device) -> String {
        "using the only connected Android device: \(device.label). Pass serial: or profile: to pin it."
    }

    public static let noDeviceMessage =
        "no Android device is connected (`adb devices` lists none)."
        + " Start an emulator with `fleetest devices up`, or connect a device with USB debugging enabled."

    public static func ambiguousMessage(_ devices: [Device]) -> String {
        "several Android devices are connected: \(devices.map(\.label).joined(separator: ", "))."
            + " Pass serial: to pick one, or profile: to use a run profile's device."
    }
}
