// RecorderWatch.swift
// 止める期限を過ぎてもまだ動いている `simctl io recordVideo` の client を見張る(`fleetest api recorder-watch` の本体)。
// 呼び手(IOSSimulatorVideoRecorder / HostRecordingProbe)は期限で process を手放すので、見張りが止めないと stop() でも
// 止まらず、後から撮り始めた録画がデバイスを塞ぎ、ファイルが残る。
//
// 見張りは fleetest より長生きする別プロセスとして起こす(`IOSSimulatorVideoRecorder.handOff`)。プロセスの中のタスクでは、
// fleetest が先に終わった後で撮り始めた client を誰も止めない。規律: SIGINT だけを送る(SIGKILL / SIGTERM は端末側の録画
// セッションを残す = RecordingKillDisciplineTests が走査)。

import Foundation

public enum RecorderWatch {
    /// SIGINT を送り直す間隔(秒)。recordVideo は実測で起動から 0.5 秒までに撮り始める(負荷で延びる)。
    /// 撮り始める前の SIGINT は無視されるので、撮り始めるまで送り直す
    public static let repeatIntervalSeconds: Double = 0.2

    /// client の身元。pid + 起動時刻(µs)。pid が使い回されても起動時刻は一致しない。
    /// **呼び手は spawn の直後に採る**(その時点の pid は自分の子で、使い回されていない)
    public struct Target: Equatable, Sendable {
        public let pid: pid_t
        public let startedMicroseconds: Int64
        public init(pid: pid_t, startedMicroseconds: Int64) {
            self.pid = pid
            self.startedMicroseconds = startedMicroseconds
        }
        /// 生きているプロセスの身元(読めなければ nil)
        public static func of(_ pid: pid_t) -> Target? {
            guard case .alive(let micros) = ProcessLiveness.observe(pid) else { return nil }
            return Target(pid: pid, startedMicroseconds: micros)
        }
    }

    public typealias Observation = ProcessLiveness.Observation

    public enum Action: Equatable, Sendable {
        /// 生きていて身元が一致する: SIGINT を送る
        case interrupt
        /// 観測できない: 送らず・消さず・終わらず、次の周で見直す
        case hold
        /// 居ない(終わった)か、別のプロセスに使い回された pid: 終わる
        case finish
    }

    /// 判定(純粋関数)
    public static func decide(_ observation: Observation, target: Target) -> Action {
        switch observation {
        case .gone: return .finish
        case .unreadable: return .hold
        case .alive(let micros): return micros == target.startedMicroseconds ? .interrupt : .finish
        }
    }

    /// 本体。`finish` になるまで周り(interrupt は送る・hold は送らずに待つ)、抜けたら `file` と **`<file の名前>.sb-` で始まる兄弟**
    /// (simctl の一時ファイル。最終名へ rename される前に client が止まると残る)を消して戻る。
    /// **見張りへ渡すファイル名は呼び出し・recorder をまたいで一意**(呼び手の契約 = `IOSSimulatorVideoRecorder.outputURL` /
    /// `HostRecordingProbe.probeFileURL`)なので、別の client の一時ファイルに当たらない。
    /// 撮り始めた後も送り続ける —— この client の録画は捨てるので SIGINT が重なっても害が無い(`interruptRecorder` の
    /// 「撮り始めたら 1 回」は残す録画のための規律)。上限は置かない(観測できない間は何もしない。1 周は sysctl 1 回)。
    /// `stdin`(client の stderr)は `drain` が EOF まで読み捨てる —— **合流しない**(見張りの寿命は client の寿命で、EOF には依存しない。
    /// client の stderr を継いだ孫が書き端を握り続けても本体は戻る。`api recorder-watch` は戻ったらプロセスごと終わる)
    public static func run(target: Target, file: URL, stdin: FileHandle?,
                           interval: Double = repeatIntervalSeconds,
                           observe: @escaping @Sendable (pid_t) -> Observation = ProcessLiveness.observe,
                           sendInterrupt: @escaping @Sendable (pid_t) -> Void = { kill($0, SIGINT) }) async {
        if let stdin { drain(stdin) }
        while true {
            switch decide(observe(target.pid), target: target) {
            case .finish:
                removeOutputs(of: file)
                return
            case .interrupt:
                sendInterrupt(target.pid)
            case .hold:
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// 最終名と、その一時ファイル(`<名前>.sb-…`)を消す
    public static func removeOutputs(of file: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: file)
        let directory = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + ".sb-"
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// `handle` を EOF まで読んで捨てる。**行に分けない**(`ScenarioHost.lineStream` の `LineBuffer` は改行まで保持するので、
    /// 改行の無い出力で育つ)。読むたびに autoreleasepool で区切る(`availableData` の NSData は自動解放)。
    /// 読み手は FileHandle の内部キューで動き、呼び手は待たない。`onChunk` は捨てたバイト数(テストの観測用)
    public static func drain(_ handle: FileHandle, onChunk: (@Sendable (Int) -> Void)? = nil) {
        handle.readabilityHandler = { handle in
            autoreleasepool {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    onChunk?(chunk.count)
                }
            }
        }
    }
}
