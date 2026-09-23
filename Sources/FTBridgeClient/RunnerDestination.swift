import Foundation

/// XCUITest ランナー(`xcodebuild test-without-building`)のコマンド行から**宛先のデバイス**を読む。
///
/// **なぜ要るのか**: 残骸ランナーの照合は `FleetestRunner-<port>.xctestrun` のパスだけで行っていた。
/// ファイル名はポートしか持たないので、**同じ種別(実機どうし・シミュレータどうし)の別デバイスが
/// 同じポートに居ると、生きているブリッジを「自分の残骸」として殺す**。
/// 実地 2026-09-23 の負荷テスト: ブリッジを失った実機2台がどちらも既定ポート 8123 へ倒れ、
/// 互いのランナーを `Cleaned up leftover runner(s) on port 8123` で殺し合った
/// (同じ形で、MCP が駆動中だったシミュレータのブリッジも巻き添えになりうる)。
///
/// 判定は**肯定的に別デバイスと分かったときだけ**効かせる(宛先が読めない・こちらの device が
/// UDID の形でない = 名前指定のときは従来どおり止める)—— 「分からないから残す」に倒すと、
/// 本物の残骸が永久に残ってポートを塞ぐ。
enum RunnerDestination {

    /// `-destination platform=iOS Simulator,id=<UDID>` の `id=` を読む
    static func udid(inCommand command: String) -> String? {
        guard let range = command.range(of: "-destination ") else { return nil }
        let rest = command[range.upperBound...]
        guard let idRange = rest.range(of: "id=") else { return nil }
        let value = rest[idRange.upperBound...].prefix { !$0.isWhitespace && $0 != "," }
        return value.isEmpty ? nil : String(value)
    }

    /// シミュレータの UUID(8-4-4-4-12)と実機の UDID(8桁-16桁)だけを「デバイスの識別子」と見る。
    /// `bridge up --device "iPhone 17 Pro"` のような**名前**とは比較しない
    static func isUDIDShaped(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let hex = { (s: Substring) in !s.isEmpty && s.allSatisfy { $0.isHexDigit } }
        if parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12], parts.allSatisfy(hex) { return true }
        if parts.count == 2, parts.map(\.count) == [8, 16], parts.allSatisfy(hex) { return true }
        return false
    }

    /// コマンド行に現れる**デバイスの識別子らしき文字列**を全部拾う(`-destination id=…` /
    /// `/CoreSimulator/Devices/<UUID>/` / `iproxy … -u <UDID>` のどれでも取れる)
    static func udidTokens(inCommand command: String) -> [String] {
        command.split(whereSeparator: { " \t\n=,/:".contains($0) })
            .map(String.init)
            .filter(isUDIDShaped)
    }

    /// このポートの残骸として止めてよいか。`.leaveAlone` は**別のデバイスのランナー**と読めた回だけ
    static func belongsToOtherDevice(command: String, ourDevice: String) -> String? {
        guard isUDIDShaped(ourDevice), let destination = udid(inCommand: command),
              destination.caseInsensitiveCompare(ourDevice) != .orderedSame else { return nil }
        return destination
    }
}
