// api monitor の devices[].foldable(折りたたみ機か)を周期から切り離す。
// 周期は foldable(for:)(控えを返し、答えが無ければ背景へ1本積むだけ・待たない)しか呼ばない。
// 計測は同期呼び出し(devicectl 最大15秒 / adb 最大15秒)なので専用の DispatchQueue で回す。
// **確定した答え(折りたためる/折りたためない)だけ控える**。unknown は控えず、間隔を空けて撃ち直す。

import FTAndroid
import FTCore
import Foundation

/// `@unchecked Sendable`: 可変の欄(answers・inFlight・lastAttemptAt)は `lock` の中でだけ読み書きする
final class DeviceFoldabilitySampler: @unchecked Sendable {
    /// 観測が unknown(読めなかった・起動途中)だった端末を撃ち直すまでの間隔(秒)。
    /// 観測1回が最大15秒(devicectl / adb の timeout)なので、毎周期(約2秒)撃ち直すと背景の
    /// キューが詰まる。起動直後の読み損ねは数十秒で解消するため60秒で足りる。
    /// 尽きたときの発話は無い(foldable が nil のままになり、拡張は折りたたみボタンを出さない)
    static let retryIntervalSeconds: TimeInterval = 60

    /// 計測の対象。key = 控えの識別子
    struct Device: Equatable {
        let key: String
        let probe: Kind
    }

    enum Kind: Equatable {
        case iosSimulator(udid: String)
        case androidEmulator(serial: String)
    }

    typealias Probe = @Sendable (Kind) -> FoldObservation

    private let lock = NSLock()
    private var answers: [String: Bool] = [:]
    private var inFlight: Set<String> = []
    private var lastAttemptAt: [String: Date] = [:]
    private let queue = DispatchQueue(label: "fleetest.monitor.foldability", qos: .utility)
    private let probe: Probe
    private let now: @Sendable () -> Date

    /// テストの差し替え口。本番は `init()`
    init(probe: @escaping Probe, now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.now = now
    }

    convenience init() {
        self.init(probe: { kind in
            switch kind {
            case .iosSimulator(let udid):
                return FoldControl.observeIOSSimulator(udid: udid)
            case .androidEmulator(let serial):
                guard let adbPath = try? AndroidDriver.findADB(),
                      let output = try? Shell.run([adbPath, "-s", serial, "shell", AdbPolicy.foldStateCommand],
                                                  timeout: AndroidHealthProbe.adbTimeoutSeconds).outputIfSucceeded
                else { return .unknown("adb did not answer the device_state query") }
                return FoldControl.observe(androidDeviceState: output)
            }
        })
    }

    /// 控えの識別子と計測の種類。**実機は呼び手が false にする(ここへ来ない)**。
    /// iOS は udid(1 udid = 1 シミュレータで機種は変わらない)。Android は id + serial
    /// (emulator-5554 は、そのポートで次に起動した AVD に再利用される)
    static func device(platform: String, id: String, udid: String?, serial: String?) -> Device? {
        if platform == "ios", let udid { return Device(key: "ios:\(udid)", probe: .iosSimulator(udid: udid)) }
        if platform == "android", let serial {
            return Device(key: "android:\(id):\(serial)", probe: .androidEmulator(serial: serial))
        }
        return nil
    }

    /// 周期から毎回呼ぶ(待たない)。確定済みならその答え、無ければ nil を返し、
    /// 計測中でなく撃ち直しの間隔も経っていれば背景で1回測る。
    /// **判定と inFlight / lastAttemptAt の更新は同じロックの中**(同時に呼んでも二重に積まない)
    func foldable(for device: Device) -> Bool? {
        lock.lock()
        if let answer = answers[device.key] {
            lock.unlock()
            return answer
        }
        let due = !inFlight.contains(device.key)
            && (lastAttemptAt[device.key].map { now().timeIntervalSince($0) >= Self.retryIntervalSeconds } ?? true)
        if due {
            inFlight.insert(device.key)
            lastAttemptAt[device.key] = now()
        }
        lock.unlock()
        guard due else { return nil }
        queue.async { [self] in
            let observation = probe(device.probe)
            lock.lock()
            inFlight.remove(device.key)
            switch observation {
            case .notFoldable: answers[device.key] = false
            case .state: answers[device.key] = true
            case .unknown: break
            }
            lock.unlock()
        }
        return nil
    }

    /// 居なくなった端末の控えを捨てる(キーが増え続けない)
    func forget(keysNotIn live: Set<String>) {
        lock.lock()
        answers = answers.filter { live.contains($0.key) }
        lastAttemptAt = lastAttemptAt.filter { live.contains($0.key) || inFlight.contains($0.key) }
        lock.unlock()
    }
}
