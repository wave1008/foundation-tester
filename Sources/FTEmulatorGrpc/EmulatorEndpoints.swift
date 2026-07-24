// エミュレータ gRPC エンドポイントのディスカバリ。
// emulator は起動毎に ~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini へ
// grpc.port / grpc.token / avd.id / port.serial を書く(トークンはブート毎に変わる)。
// 認証は `authorization: Bearer <grpc.token>` メタデータのみで通る(emulator 36.5.10 実測。
// JWT/JWK は不要)。ファイルが残っていてもプロセス死亡なら無効(kill(pid,0) で生存確認)。

import Foundation

public struct EmulatorEndpoint: Sendable, Equatable {
    public let serial: String   // "emulator-5554"
    public let avdID: String    // "Pixel_9_Android_15_-01"
    public let grpcPort: Int
    public let token: String
    public let pid: Int32       // 同一 serial の再ブート判別に使う(フォールバック記憶のキー)

    public init(serial: String, avdID: String, grpcPort: Int, token: String, pid: Int32) {
        self.serial = serial
        self.avdID = avdID
        self.grpcPort = grpcPort
        self.token = token
        self.pid = pid
    }
}

public enum EmulatorEndpoints {

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    }

    /// serial に対応する稼働中エンドポイントを返す(無ければ nil = 実機 or gRPC 情報なし)
    public static func endpoint(serial: String, directory: URL? = nil) -> EmulatorEndpoint? {
        all(directory: directory).first { $0.serial == serial }
    }

    /// 稼働中(プロセス生存確認済み)の全エンドポイント
    public static func all(directory: URL? = nil) -> [EmulatorEndpoint] {
        let dir = directory ?? defaultDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.compactMap { name -> EmulatorEndpoint? in
            guard name.hasPrefix("pid_"), name.hasSuffix(".ini"),
                  let pid = Int32(name.dropFirst(4).dropLast(4)),
                  kill(pid, 0) == 0,
                  let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            else { return nil }
            return parse(text: text, pid: pid)
        }
    }

    /// ディスカバリ ini の parse(テスト用に公開。書式: `key=value` 行の羅列)
    public static func parse(text: String, pid: Int32) -> EmulatorEndpoint? {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let avdID = values["avd.id"],
              let serialPort = values["port.serial"],
              let grpcPort = values["grpc.port"].flatMap(Int.init),
              let token = values["grpc.token"], !token.isEmpty
        else { return nil }
        return EmulatorEndpoint(
            serial: "emulator-\(serialPort)", avdID: avdID,
            grpcPort: grpcPort, token: token, pid: pid)
    }
}
