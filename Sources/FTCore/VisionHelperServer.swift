// 補助プロセス(`fleetest api vision-serve`)の本体。起動したらすぐ暖機し、健全になるまで要求に unhealthy で答える。
// **1 つのスレッドが暖機・accept・処理を順に回す** = Vision の計算を並行に撃たない(暖機も要求も同じ直列)。
// 同期相手: クライアントは VisionHelper.swift・コマンドは Sources/fleetest/ApiVisionServeCommand.swift。
//
// 健全性の門は `FindImage+Prewarm.swift` の `isHealthy` と同じ2つ(白紙との縮退・測り直しの一致)。違うのは**見本が無い**ので
// 固定の探り画像(`probeImage`)の特徴量で見ること。**要求の画像そのものは白紙と比べない**(白い切り出しは正常にありうる。
// 白紙との距離 0 を要求の画像で見ると、白いボタンを毎回 unhealthy にする)。

import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum VisionHelperServer {
    /// 暖機の上限・間隔は `FindImage.prewarmBudget` / `prewarmInterval` をそのまま使う(新しい定数を置かない)。
    /// 上限が尽きたら unhealthy のまま要求に答え続ける(クライアントは既存の待ち直しへ落ちる)

    /// 白黒の市松(64 x 64・8 画素の升)。一様な白とは別物の絵 = 健全な Vision なら白紙の特徴量と距離 0 にならない
    static let probeImage: CGImage = {
        let size = 64
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for row in 0..<8 {
            for column in 0..<8 where (row + column) % 2 == 0 {
                context.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
            }
        }
        return context.makeImage()!
    }()

    /// 健全性の判定(純粋関数。テストは破れる観測を渡す): 探り画像と白紙が別の特徴量で、探り画像を測り直しても一致する
    static func isHealthy(probeDistanceToBlank: Double, probeSelfDistance: Double) -> Bool {
        !FindImage.isDegenerate(templateDistanceToBlank: probeDistanceToBlank)
            && FindImage.isConsistent(selfDistance: probeSelfDistance)
    }

    static func checkHealth() async -> Bool {
        do {
            let request = GenerateImageFeaturePrintRequest()
            let blank = try await request.perform(on: FindImage.blankSentinel)
            let probe = try await request.perform(on: probeImage)
            let again = try await request.perform(on: probeImage)
            return isHealthy(probeDistanceToBlank: Double(try probe.distance(to: blank)),
                             probeSelfDistance: Double(try probe.distance(to: again)))
        } catch {
            return false
        }
    }

    /// 1 要求の処理(要求の復号 → 健全性の門 → 特徴量)。`healthy` は暖機の結果の控え。戻り値の `healthy` は
    /// 処理後の値(門で落ちたら false に戻す = 呼び手が暖機をやり直す)
    static func respond(to payload: Data, healthy: Bool, checkHealth: () async -> Bool,
                        computePrint: (CGImage) async throws -> FeaturePrintObservation)
        async -> (response: VisionHelperWire.Response, healthy: Bool) {
        guard healthy else { return (VisionHelperWire.Response(status: .unhealthy), false) }
        guard let request = try? JSONDecoder().decode(VisionHelperWire.Request.self, from: payload),
              let source = CGImageSourceCreateWithData(request.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return (VisionHelperWire.Response(status: .failed, detail: "the request is not a readable PNG"), true)
        }
        // 答える前に毎回、今の Vision が縮退していないことを確かめる(暖機の後に崩れた回の砦)
        guard await checkHealth() else { return (VisionHelperWire.Response(status: .unhealthy), false) }
        do {
            return (VisionHelperWire.Response(status: .ok, print: try await computePrint(image)), true)
        } catch {
            return (VisionHelperWire.Response(status: .failed, detail: "\(error)"), true)
        }
    }

    /// 同期スレッドから async を呼んで待つ(この関数を呼ぶスレッドは 1 本だけ = Vision の計算は直列)。
    /// `UncheckedTransfer` の根拠: 値は Task の中で作られ、semaphore の後に 1 度だけ読まれる(同時に触る者は居ない)
    private static func blocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedValue<UncheckedTransfer<T>?>(nil)
        Task.detached {
            let value = await body()
            box.withLock { $0 = UncheckedTransfer(value) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.withLock { $0 }!.value
    }

    /// 同名のソケットが残っていれば、繋がる(= 生きた持ち主が居る)なら false。繋がらなければ古い残骸として消して true。
    /// ほかの `vision-<pid>.sock` も、pid が死んでいれば消す(SIGKILL された補助は自分で消せない)
    static func prepareSocketPath(_ path: String, log: (String) -> Void) -> Bool {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let own = URL(fileURLWithPath: path).lastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name != own && name.hasPrefix("vision-") && name.hasSuffix(".sock") {
            let digits = name.dropFirst("vision-".count).dropLast(".sock".count)
            if let pid = pid_t(digits), !ProcessLiveness.isAlive(pid) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return true }
        defer { close(probe) }
        let connected = VisionHelperWire.withAddress(path: path) { connect(probe, $0, $1) } ?? -1
        if connected == 0 {
            log("a live process already serves \(path)")
            return false
        }
        unlink(path)
        return true
    }

    /// 終了するまで戻らない。`shouldStop` は別スレッド(stdin 監視・シグナル)が立てる。戻り値 = 終了コード
    public static func run(socketPath: String, shouldStop: @escaping @Sendable () -> Bool,
                           log: @escaping @Sendable (String) -> Void) -> Int32 {
        guard prepareSocketPath(socketPath, log: log) else { return 1 }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { log("socket: errno \(errno)"); return 1 }
        defer { close(listener); unlink(socketPath) }
        let bound = VisionHelperWire.withAddress(path: socketPath) { bind(listener, $0, $1) } ?? -1
        guard bound == 0 else { log("bind \(socketPath): errno \(errno)"); return 1 }
        chmod(socketPath, 0o600)
        guard listen(listener, 16) == 0 else { log("listen: errno \(errno)"); return 1 }

        var healthy = false
        var warming = true
        var warmedSince = ContinuousClock.now
        let pollIntervalMs = Int32(FindImage.prewarmInterval.components.seconds * 1000
                                   + FindImage.prewarmInterval.components.attoseconds / 1_000_000_000_000_000)
        while !shouldStop() {
            if !healthy, warming {
                autoreleasepool {
                    if blocking({ await checkHealth() }) {
                        healthy = true
                        warming = false
                        log("Vision is healthy")
                    } else if ContinuousClock.now - warmedSince > FindImage.prewarmBudget {
                        warming = false
                        log("Vision did not become healthy within the warm-up budget; answering unhealthy")
                    }
                }
            }
            // 暖機中は間隔どおりに回す。健全・諦めた後は終了の検知のために 0.5 秒おきに起きる
            var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, healthy || !warming ? 500 : pollIntervalMs) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            autoreleasepool {
                defer { close(connection) }
                // 要求ごとの期限(読めない・遅いクライアントに直列の処理を塞がせない)
                VisionHelperWire.setTimeouts(connection, seconds: VisionHelperWire.requestDeadlineSeconds)
                let deadline = Date().addingTimeInterval(VisionHelperWire.requestDeadlineSeconds)
                guard let payload = VisionHelperWire.readPayload(connection, deadline: deadline) else { return }
                let wasHealthy = healthy
                let outcome = blocking {
                    await respond(to: payload, healthy: wasHealthy, checkHealth: { await checkHealth() },
                                  computePrint: { try await GenerateImageFeaturePrintRequest().perform(on: $0) })
                }
                if wasHealthy, !outcome.healthy {
                    // 門で落ちた: 暖機をやり直す(上限は落ちた時点から数え直す)
                    healthy = false
                    warming = true
                    warmedSince = ContinuousClock.now
                    log("Vision degraded; warming up again")
                }
                if let frame = try? VisionHelperWire.encode(outcome.response) {
                    _ = VisionHelperWire.writeAll(connection, frame, deadline: deadline)
                }
            }
        }
        return 0
    }
}
