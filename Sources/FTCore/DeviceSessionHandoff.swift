// DeviceSessionHandoff.swift
// デバイスセッション(1回の run × 1デバイスで共有する状態 = メモと setUpDevice の済み印)の親→子の受け渡し。
// プロトコル:
//   親→子: 子を `--device-session-stdin` で起動し、stdin の**1行目**にこの DTO を NDJSON 1行で書く。
//     子は他の何より先に1行目を読む(debug / host-install の制御コマンドは2行目以降)。
//   子→親: ScenarioEvent の memoWrite / memoClear / deviceSetUp(ScenarioEvent.swift 冒頭)。
// 親側の状態は RunDeviceSession.swift、子側は FTDriveCore(FTDSL)。
// 1台のデバイスはシナリオを1本ずつ順に回すので、起動時の写し + 書き込みの片道通知で
// 次のシナリオは必ず最新を受け取る(ScenarioHost が子の stdout を読み切ってから戻るため)。

import Foundation

public struct DeviceSessionHandoff: Codable, Sendable, Equatable {
    /// 常に "deviceSession"(stdin の他の制御コマンドと同じく cmd で種別を示す)
    public var cmd: String
    /// キー → 書いた順の値(Shirates の Memo と同じく履歴を持ち、readMemo は最後の値)
    public var memo: [String: [String]]
    /// true = このシナリオの前に setUpDevice を走らせる(このデバイスでこのクラスは未試行)
    public var runSetUpDevice: Bool

    public static let command = "deviceSession"

    public init(memo: [String: [String]], runSetUpDevice: Bool) {
        self.cmd = Self.command
        self.memo = memo
        self.runSetUpDevice = runSetUpDevice
    }

    /// stdin へ書く1行(改行は含まない)
    public func encodedLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let line = String(data: data, encoding: .utf8) else {
            return #"{"cmd":"deviceSession","memo":{},"runSetUpDevice":false}"#
        }
        return line
    }

    /// cmd が deviceSession でない・壊れている行は nil
    public static func decode(line: String) -> DeviceSessionHandoff? {
        guard let data = line.data(using: .utf8),
              let handoff = try? JSONDecoder().decode(DeviceSessionHandoff.self, from: data),
              handoff.cmd == command else { return nil }
        return handoff
    }
}
