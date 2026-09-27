// iOS Simulator のデータディレクトリの大きさ・ホストボリュームの空きを低頻度で確認する
// (ApiMonitorCommand.swift から呼ばれる)。シミュレータの「ストレージ」はホストのディスクを
// 間借りしているだけなので、空きが意味を持つのはホスト側(freeScope: hostVolume)。
// 実機はここでは測れない(呼び出し側が仮想デバイスだけを候補にする)。

import Darwin
import FTCore
import Foundation

public enum SimulatorStorageProbe {
    /// 計測間隔(秒)。**根拠**: 並列走査で 1 台約 4 秒(4 スレッド・データ 7.9GB / 16 万ファイル・
    /// load avg 11〜19 の実測)。ストレージの逼迫は分単位でしか動かないので即応性は要らない。
    /// 起動し直した台は間隔を待たない(DeviceStorageSampler.noteConnected)
    public static let probeIntervalSeconds: TimeInterval = 1800

    /// 走査の締切(秒)。**根拠**: 単一スレッドの du の最悪実測 28 秒の約 10 倍。超えたら今回は諦めて
    /// 前回値を配り続ける。**判定はディレクトリ 1 つ読むごと** —— 固まったボリュームの syscall の中からは
    /// 抜けられない(その間 iOS の計測キューは止まるが、配信の周期は止めない)
    static let walkTimeoutSeconds: TimeInterval = 300

    /// 走査のスレッド数 = CPU コア数の半分(ユーザー決定。8 コア → 4)。律速はカーネルのメタデータ処理
    /// (sys 時間)で、単一スレッドは API を変えても du と同じ(12〜14 秒)。並列にすると壁時計だけが縮み、
    /// CPU の合計はほぼ同じ(1 本 sys 5.5 秒 → 4 本 7.3 秒)
    static func walkerThreads(cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        max(1, cores / 2)
    }

    /// 取得・解析できなければ nil(呼び出し側は前回値を配り続ける。0 で埋めない)
    public static func probe(udid: String, now: Date = Date()) -> DeviceStorageInfo? {
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data")
        guard FileManager.default.fileExists(atPath: dataDir.path) else { return nil }
        guard let usedBytes = allocatedBytes(under: dataDir, threads: walkerThreads(),
                                             deadline: now.addingTimeInterval(walkTimeoutSeconds))
        else { return nil }
        let freeBytes = hostVolumeFreeBytes(at: dataDir)
        return DeviceStorageInfo(usedBytes: usedBytes, freeBytes: freeBytes, freeScope: .hostVolume,
                                 measuredAt: ISO8601DateFormatter().string(from: now))
    }

    /// `root` 以下のディスク上の占有量(バイト)。du -sk と同じ量を数える —— **隠しファイルも含め**、
    /// 見かけの大きさ(`fileSize`)ではなく**割り当て済みの大きさ**(`totalFileAllocatedSize`。
    /// 見かけで数えると実測 4% 少なく出る)。シンボリックリンクは辿らない。ハードリンクは du と違い
    /// 重複して数える(実測の差 0.08%)。読めないディレクトリは飛ばす。締切を過ぎたら nil。
    /// 各スレッドは I/O を throttle にする(`taskpolicy -d throttle` 相当・run の I/O を先に通す)。
    /// **background QoS にしない** —— CPU も E コアへ回され、キャッシュが温まっていても所要が倍になる(実測)
    static func allocatedBytes(under root: URL, threads: Int, deadline: Date) -> Int? {
        let walk = ParallelWalk(root: root, deadline: deadline)
        let done = DispatchGroup()
        for _ in 0..<max(1, threads) {
            done.enter()
            let thread = Thread {
                setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
                walk.work()
                done.leave()
            }
            thread.qualityOfService = .utility
            thread.start()
        }
        done.wait()
        return walk.result()
    }

    /// `path` があるボリュームの空き(バイト)。statfs 相当(`URL.resourceValues`)で
    /// サブプロセスを起こさない
    static func hostVolumeFreeBytes(at url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage }
            .map { Int($0) }
    }
}

/// 共有のディレクトリのスタックを複数スレッドで消化する。**終わりの判定は「スタックが空 かつ 読み中の
/// スレッドが 0」** —— 空になっただけで抜けても値は正しい(積んだスレッドが自分で拾う)が、最初の 1 本以外が
/// 根を読む間に抜けて単一スレッドの走査に戻る(テストでは落ちない。所要でしか見えない)
private final class ParallelWalk: @unchecked Sendable {
    private static let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
    private let condition = NSCondition()
    private var pending: [URL]
    private var reading = 0
    private var total = 0
    private var timedOut = false
    private let deadline: Date

    init(root: URL, deadline: Date) {
        pending = [root]
        self.deadline = deadline
    }

    func work() {
        var localTotal = 0
        while let dir = next() {
            var subdirs: [URL] = []
            autoreleasepool {
                let items = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: Array(Self.keys), options: [])) ?? []
                for item in items {
                    guard let values = try? item.resourceValues(forKeys: Self.keys) else { continue }
                    // resourceValues はリンクを辿らない(ディレクトリへのリンクも isDirectory == false)
                    if values.isDirectory == true {
                        subdirs.append(item)
                    } else {
                        localTotal += values.totalFileAllocatedSize ?? 0
                    }
                }
            }
            condition.lock()
            pending.append(contentsOf: subdirs)
            reading -= 1
            condition.broadcast()
            condition.unlock()
        }
        condition.lock()
        total += localTotal
        condition.unlock()
    }

    /// 次に読むディレクトリ。nil = 終わり(全部読んだ・締切を過ぎた)
    private func next() -> URL? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if timedOut { return nil }
            if Date() > deadline {
                timedOut = true
                condition.broadcast()
                return nil
            }
            if let dir = pending.popLast() {
                reading += 1
                return dir
            }
            if reading == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    func result() -> Int? {
        condition.lock()
        defer { condition.unlock() }
        return timedOut ? nil : total
    }
}
