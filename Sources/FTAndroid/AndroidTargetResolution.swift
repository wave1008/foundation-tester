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
        if let explicit, !explicit.isEmpty {
            if let refusal = explicitSerialRefusal(
                serial: explicit, listed: try? AndroidDeviceCatalog.listedSerialStates()) {
                throw refusal
            }
            return explicit
        }
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

extension AndroidTargetResolution {
    /// 明示された serial を `adb devices` の**全行(状態つき)**と照らす(純粋関数)。**一覧に1行も無いときだけ**断る ——
    /// 断らないと adb forward の失敗が「止まっている・応答が遅い」という案内に化けていた(負荷テストの CLI ファズ)。
    /// offline / unauthorized は「居ない」ではない(state=device だけを数える `connectedSerials` で照らすと誤る)
    /// ので断らず、adb の失敗文に事実を言わせる。一覧が引けない(nil)は不明 = 断らない
    public static func explicitSerialRefusal(serial: String, listed: [String: String]?) -> AndroidTargetError? {
        guard let listed, listed[serial] == nil else { return nil }
        return .notListed(serial: serial)
    }
}

/// Android デバイス選択の失敗。**文言は持たない** —— `errorDescription` は
/// AndroidSerialResolver の対応する値/関数をそのまま返す
public enum AndroidTargetError: Error, LocalizedError, Equatable {
    case noDevice
    case ambiguous(devices: [AndroidSerialResolver.Device])
    case notListed(serial: String)

    public var errorDescription: String? {
        switch self {
        case .noDevice:
            return AndroidSerialResolver.noDeviceMessage
        case .ambiguous(let devices):
            return AndroidSerialResolver.ambiguousMessage(devices)
        case .notListed(let serial):
            return AndroidSerialResolver.notListedMessage(serial: serial)
        }
    }
}
