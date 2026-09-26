// iOS Simulator のデータディレクトリの大きさ・ホストボリュームの空きを低頻度で確認する
// (ApiMonitorCommand.swift から呼ばれる)。シミュレータの「ストレージ」はホストのディスクを
// 間借りしているだけなので、空きが意味を持つのはホスト側(freeScope: hostVolume)。
// 実機はここでは測れない(呼び出し側が仮想デバイスだけを候補にする)。

import FTCore
import Foundation

public enum SimulatorStorageProbe {
    /// 計測間隔(秒)。**根拠**: du は 1 台 27〜35 秒(実測・データ 30〜37GB)で、
    /// DeviceStorageSampler が 1 台ずつ回すので 8 台で約 4〜5 分 I/O を使う。30 分おきなら
    /// I/O を使う時間は 1 割台に収まる。ストレージの逼迫は分単位でしか動かないので即応性は要らない
    public static let probeIntervalSeconds: TimeInterval = 1800

    /// `du -sk` の締切(秒)。**根拠**: 実測 27〜35 秒(上の間隔の doc)に、`taskpolicy -b`(I/O を
    /// 後回しにする)で遅くなる分を見込んで約 10 倍。超えたら今回は諦めて前回値を配り続ける
    static let duTimeoutSeconds: Double = 300

    /// 取得・解析できなければ nil(呼び出し側は前回値を配り続ける。0 で埋めない)
    public static func probe(udid: String, now: Date = Date()) -> DeviceStorageInfo? {
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data")
        guard FileManager.default.fileExists(atPath: dataDir.path) else { return nil }
        guard let usedBytes = du(path: dataDir.path) else { return nil }
        let freeBytes = hostVolumeFreeBytes(at: dataDir)
        return DeviceStorageInfo(usedBytes: usedBytes, freeBytes: freeBytes, freeScope: .hostVolume,
                                 measuredAt: ISO8601DateFormatter().string(from: now))
    }

    /// `taskpolicy -b du -sk <path>` の1K-blocks を読む。du の所要はほぼ I/O(実測 sys 14〜17 秒・
    /// user 0.3 秒)なので、CPU だけを下げる nice ではなく I/O も後回しにする background で撃つ
    static func du(path: String) -> Int? {
        guard let result = try? Shell.run(["/usr/sbin/taskpolicy", "-b", "/usr/bin/du", "-sk", path],
                                          timeout: duTimeoutSeconds),
              result.status == 0 else { return nil }
        return parse(duOutput: result.output).map { $0 * 1024 }
    }

    /// `du -sk` の1行目("<KB>\t<path>")の先頭列だけを読む。区切りはタブ・空白のどちらでも
    /// (実測は tab だが、区切りだけ違う出力に静かに 0 件化させない)
    static func parse(duOutput: String) -> Int? {
        guard let firstLine = duOutput.split(separator: "\n", omittingEmptySubsequences: true).first,
              let firstField = firstLine.split(whereSeparator: \.isWhitespace).first
        else { return nil }
        return Int(firstField)
    }

    /// `path` があるボリュームの空き(バイト)。statfs 相当(`URL.resourceValues`)で
    /// サブプロセスを起こさない
    static func hostVolumeFreeBytes(at url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage }
            .map { Int($0) }
    }
}
