// connected な Android デバイスの `/data` の使用量・空きを低頻度で確認する(ApiMonitorCommand.swift
// から呼ばれる)。df は軽い呼び出しだが、観測(計測)と配信を同じループに書かない規律
// (CLAUDE.md)に合わせて他のプローブ(AndroidHealthProbe)と同じ TTL キャッシュで間引く。

import FTCore
import Foundation

public enum AndroidStorageProbe {
    /// 計測間隔(秒)。**根拠**: ストレージの逼迫は分単位でしか動かない事象で、`df` 自体は
    /// 軽くても monitor の既定サイクル(2秒)ごとに撃つ理由が無い(観測の cadence を
    /// 配信の cadence に合わせない規律)。5分は AndroidHealthProbe の health プローブ間隔
    /// (30秒)より意図的に長い —— こちらは即応性が要らない指標のため
    public static let probeIntervalSeconds: TimeInterval = 300

    /// `adb shell df /data` の締切(秒)。AndroidHealthProbe.adbTimeoutSeconds と同じ値
    /// (wedge した adbd に無期限に握らせないための既存の基準を共有する)
    static let adbTimeoutSeconds: Double = AndroidHealthProbe.adbTimeoutSeconds

    /// 取得・解析できなければ nil(呼び出し側は前回値を配り続ける。0 で埋めない)
    public static func probe(serial: String, now: Date = Date()) -> DeviceStorageInfo? {
        guard let adbPath = try? AndroidDriver.findADB() else { return nil }
        guard let result = try? Shell.run([adbPath, "-s", serial, "shell", "df", "/data"],
                                          timeout: adbTimeoutSeconds),
              result.status == 0 else { return nil }
        guard let parsed = parse(dfOutput: result.output) else { return nil }
        return DeviceStorageInfo(usedBytes: parsed.usedBytes, freeBytes: parsed.freeBytes,
                                 freeScope: .device,
                                 measuredAt: ISO8601DateFormatter().string(from: now))
    }

    /// `df /data` の出力(1K-blocks 単位)から使用量・空き(バイト)を読む。
    /// ヘッダ行("Filesystem …")や解析できない行は無視し、**数値3列(blocks/Used/Available)を
    /// 持つ最後の行**を使う(通常は対象1行だけだが、busybox 系の折り返しに備えて後方から探す)
    static func parse(dfOutput: String) -> (usedBytes: Int, freeBytes: Int)? {
        let lines = dfOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines.reversed() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4,
                  Int(fields[1]) != nil,
                  let usedKB = Int(fields[2]), let availKB = Int(fields[3]) else { continue }
            return (usedKB * 1024, availKB * 1024)
        }
        return nil
    }
}
