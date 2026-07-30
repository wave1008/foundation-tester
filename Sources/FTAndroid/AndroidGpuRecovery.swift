// 実行開始時(ProfileWorkerFactory を呼ぶ前)に、画面凍結で CPU 描画(swiftshader)へ落ちた
// Android エミュレータを GPU(-gpu host)で起動し直す。実行プロファイルの
// recoverCpuFallbackToGpu が true のときだけ呼ばれる(既定 false)。
//
// **プロセス再起動が必須**: GPU モードは emulator の起動引数 -gpu で固定されるため、ゲスト再起動や
// gRPC RESET では戻せない(DeviceBooter.startEmulator 参照)。そのため該当機1台につき run 開始が
// 約1分延びる。戻した先で再び凍結すればモニターの watchdog がまた CPU に落とす
// (design.md §12.4 の既知トレードオフ)。
//
// 拡張(MonitorDeviceOps.cpuRenderNames)の「GPUで再起動」と目的は同じだが別経路: あちらは
// モニターの手動操作、こちらは run 開始時の自動処理で、互いの状態は共有しない
// (拡張側はモニターが再検出した renderMode を見て記憶を捨てる)。

import Foundation
import FTCore

public enum AndroidGpuRecovery {

    /// android の仮想デバイスのみ対象。GPU へ戻したデバイス名の配列を返す(失敗はログして継続)。
    /// AndroidDataWiper と同じく **1台ずつ直列**に処理する(複数台の同時ブート描画は画面凍結の
    /// トリガそのもの。実測 2026-07-25)。停止〜再ブートは1台数十秒の無音区間になるため各フェーズを
    /// 必ずログする(GUI は stderr を出力チャネルへ逐次表示する)。
    public static func recoverCpuFallbackDevices(
        devices: [ResolvedDevice], locale: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> [String] {
        // 実機は -gpu の概念が無い。avd 未指定は再起動の起動引数を組めない。
        // 現在 CPU 描画で動いている個体だけに絞る(dumpsys SurfaceFlinger。未起動・serial 未解決は
        // 対象外=次の buildAndroidWorkers が通常どおり扱う)
        var targets: [(device: ResolvedDevice, avdID: String)] = []
        for device in devices where device.platform == "android" && !device.spec.isPhysical {
            guard let avd = device.spec.avd,
                  let serial = try? AndroidDeviceCatalog.resolveSerial(spec: device.spec),
                  AndroidHealthProbe.detectRenderMode(serial: serial) == "cpu" else { continue }
            targets.append((device, AndroidDeviceCatalog.canonicalAVDID(avd)))
        }
        guard !targets.isEmpty else { return [] }

        log("🖥 Returning \(targets.count) device(s) from CPU rendering to the GPU: "
            + targets.map(\.device.name).joined(separator: ", "))
        log("   Restarting the emulator processes (the GPU mode is fixed at launch; about a minute per device)")

        var recovered: [String] = []
        for (index, target) in targets.enumerated() {
            let name = target.device.name
            let progress = "\(index + 1)/\(targets.count)"
            do {
                log("🖥 \(name): returning to the GPU (\(progress)) — stopping the emulator...")
                try await DeviceBooter.shutdownOne(spec: target.device.spec, platform: "android",
                                                  log: log)
                log("🖥 \(name): rebooting on the GPU (-gpu host)...")
                let serial = try await DeviceBooter.startEmulator(avd: target.avdID,
                                                                  gpuMode: "host", locale: locale)
                try await DeviceBooter.waitForAndroidBoot(serial: serial)
                await DeviceBooter.applyLocale(serial: serial, locale: locale,
                                               deviceName: name, log: log)
                // ブートしても swiftshader のままなら復帰失敗(-gpu host が効かない構成)。
                // 起動自体は成功しているので run からは外さず、警告だけ出す
                if AndroidHealthProbe.detectRenderMode(serial: serial) == "cpu" {
                    log("⚠️ \(name): still on CPU rendering after the restart (\(progress))")
                } else {
                    recovered.append(name)
                    log("✅ \(name): back on GPU rendering (\(progress), \(serial))")
                }
            } catch {
                log("❌ \(name): GPU recovery failed — \(error.localizedDescription)")
            }
        }
        return recovered
    }
}
