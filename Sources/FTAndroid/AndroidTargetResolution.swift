// serial を渡さない呼び出し(MCP の ft_* / CLI の手動駆動サブコマンド)向けのデバイス選択。
// iOS の `FTBridgeClient.BridgeTargetResolution` と同じ役割・同じ設計(判定はここ・
// 文言は AndroidSerialResolver の1箇所)だが、**別ファイル・別モジュールに置く**——
// FTAndroid は FTBridgeClient に依存する向きなので、あちらの enum へは合流できない
// (逆に FTBridgeClient から AndroidSerialResolver は参照できない)。

import FTCore
import Foundation

public enum AndroidTargetResolution {

    /// serial 無しで adb を撃たない(複数台なら "more than one device/emulator" が生で出る)。
    /// `log` は自動採用したときの理由だけを渡す。
    public static func serial(explicit: String?, log: (String) -> Void) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        let serials = AndroidSerialResolver.connectedSerials()
        switch AndroidSerialResolver.decide(explicit: nil, connected: serials) {
        case .use(let serial):
            log(AndroidSerialResolver.adoptedNote(
                AndroidSerialResolver.describe(serials: [serial])[0]))
            return serial
        case .none:
            throw AndroidTargetError.noDevice
        case .ambiguous(let devices):
            throw AndroidTargetError.ambiguous(
                devices: AndroidSerialResolver.describe(serials: devices.map(\.serial)))
        }
    }
}

/// Android デバイス選択の失敗。**文言は持たない** —— `errorDescription` は
/// AndroidSerialResolver の対応する値/関数をそのまま返す
public enum AndroidTargetError: Error, LocalizedError, Equatable {
    case noDevice
    case ambiguous(devices: [AndroidSerialResolver.Device])

    public var errorDescription: String? {
        switch self {
        case .noDevice:
            return AndroidSerialResolver.noDeviceMessage
        case .ambiguous(let devices):
            return AndroidSerialResolver.ambiguousMessage(devices)
        }
    }
}
