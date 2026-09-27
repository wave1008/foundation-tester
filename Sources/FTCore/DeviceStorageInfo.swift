// DeviceStorageInfo.swift
// `fleetest api monitor` の monitorDevices[].storage(任意)。実機は測れないので省く
// (測れなかった台も省く。0 で埋めない)。計測の実体は Android = FTAndroid.AndroidStorageProbe
// (df /data)・iOS Simulator = FTBridgeClient.SimulatorStorageProbe(データディレクトリの並列走査 +
// ホストボリュームの空き)。docs/results-json.md は対象外(この欄は results/ ではなく
// api monitor の NDJSON だけに出る)。

import Foundation

/// `DeviceStorageInfo.freeBytes` の意味範囲。Android は device(ゲストの /data 自体)、
/// iOS Simulator はホストボリューム(シミュレータの実体はホストのディスクを間借りするため、
/// 「空き」が意味を持つのはホスト側)
public enum DeviceStorageFreeScope: String, Codable, Sendable {
    case device
    case hostVolume
}

public struct DeviceStorageInfo: Codable, Sendable, Equatable {
    /// Android: `df /data` の使用量(バイト) / iOS Simulator: データディレクトリの大きさ(バイト)
    public var usedBytes: Int
    /// Android: `df /data` の空き(バイト) / iOS Simulator: そのディレクトリがあるホストボリュームの
    /// 空き(バイト。`statfs`)。測れなければ省く
    public var freeBytes: Int?
    public var freeScope: DeviceStorageFreeScope
    /// ISO8601
    public var measuredAt: String
    /// true = 前の monitor が測って ~/.fleetest/device-storage.json に残した値で、この monitor はまだ
    /// 測り直していない(拡張は灰色で出す)。計測関数が作る値は常に false。
    /// 契約は vscode-fleetest/src/monitorDeviceModel.ts の MonitorDeviceStorage.carriedOver
    public var carriedOver: Bool

    public init(usedBytes: Int, freeBytes: Int? = nil, freeScope: DeviceStorageFreeScope,
                measuredAt: String, carriedOver: Bool = false) {
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.freeScope = freeScope
        self.measuredAt = measuredAt
        self.carriedOver = carriedOver
    }
}
