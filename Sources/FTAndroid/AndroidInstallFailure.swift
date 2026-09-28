// AndroidInstallFailure.swift
// `adb install` の失敗のうち「容器(guest の /data)が満杯」を見分けて、Wipe Data → 1回だけ入れ直す。
//
// `wipeDataOnBloat` はホスト側の userdata/cache/snapshots の合計(閾値 8GB)を見るので、guest の /data だけが
// 満杯(実測 M1Ultra Pixel-07: 5.8GB 中 587MB 空き = 90%)のときは発火せず、そのレーンは
// `INSTALL_FAILED_INSUFFICIENT_STORAGE` で離脱していた。
//
// **判定は Android 側が出す2つの形**で行う(自前の文言の一致で仕分けない規律の対象外 = 相手の出力):
// - pm の状態コード名 `INSTALL_FAILED_INSUFFICIENT_STORAGE`(空きが数百 MB 残っている段。公開定数)
// - PackageInstallerService の例外 `Requested internal only, but not enough space`(さらに詰まった段。
//   セッションを作る前に落ちるので状態コードが出ない。陽性対照で /data を 96% まで埋めて実測)

import Foundation
import FTCore

public enum AndroidInstallFailure {
    /// pm の状態コード名。adb は `Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: …]` の形で出す
    public static let insufficientStorageCode = "INSTALL_FAILED_INSUFFICIENT_STORAGE"
    /// セッション作成の段で落ちたときの例外の文言(AOSP PackageInstallerService.createSession)
    public static let noSpaceForSession = "Requested internal only, but not enough space"

    /// インストール失敗の出力(`DriverError` の本文)が「容量不足」か
    public static func isInsufficientStorage(_ failureText: String) -> Bool {
        failureText.contains(insufficientStorageCode) || failureText.contains(noSpaceForSession)
    }
}

/// `ProfileWorkerFactory.installIfNeeded` が容量不足のとき使う道具。**production は AndroidDataWiper と
/// AndroidDeviceCatalog**、テストは記録する偽物を渡す(Wipe は実 AVD が要り、単体テストでは撃てない)。
/// `avdBySerial` は「稼働中の serial → AVD ID」。Wipe の前(対象の AVD を決める)と後(同じ serial で
/// 戻ってきたか)の2回引く。`awaitPackageManager` は入れ直す前に必ず待つ(起動完了の直後は package
/// サービスが応答せず install が Broken pipe で落ちる。戻り値 = 待った秒数)
public struct AndroidStorageRecovery: Sendable {
    public var avdBySerial: @Sendable () -> [String: String]
    public var wipe: @Sendable (_ deviceName: String, _ avd: String, _ locale: String,
                                _ log: @escaping @Sendable (String) -> Void) async throws -> Void
    public var awaitPackageManager: @Sendable (_ serial: String) async throws -> TimeInterval

    public init(avdBySerial: @escaping @Sendable () -> [String: String],
                wipe: @escaping @Sendable (String, String, String,
                                           @escaping @Sendable (String) -> Void) async throws -> Void,
                awaitPackageManager: @escaping @Sendable (String) async throws -> TimeInterval) {
        self.avdBySerial = avdBySerial
        self.wipe = wipe
        self.awaitPackageManager = awaitPackageManager
    }

    public static let production = AndroidStorageRecovery(
        avdBySerial: { (try? AndroidDeviceCatalog.runningAVDs()) ?? [:] },
        wipe: { name, avd, locale, log in
            try await AndroidDataWiper.wipeOne(deviceName: name, avd: avd, locale: locale, log: log)
        },
        awaitPackageManager: { try await DeviceBooter.waitForPackageManager(serial: $0) })
}
