// ScenarioEventLog.swift
// 1シナリオぶんの実行ログを <runDir>/events/<fileBase>.ndjson へ保存する書き手。
// 契約(置き場・行形式・finish 時の rename・.inflight-<UUID>.ndjson の意味)の定義元は
// docs/results-json.md §events/*.ndjson。読み手は FTCore.EventLogFormat と RetentionSweeper.eventLogSessions。
//
// ScenarioHost.run の stdout 読み取りループと stderr の detached Task が並行に append するため
// NSLock で直列化する(RunRecorder と同じ規律)。fd は1本を O_APPEND で持ち、1行ずつ write(2) で
// 書き切る。**普通のローカルファイル**(パイプではない)なので、ConsoleOut.emit が備える
// EAGAIN/ENOBUFS 再試行(非ブロッキングなパイプ/ソケット向け)は要らない —— EINTR の再試行と
// 短い write の書き切りだけで足りる。

import Foundation

public final class ScenarioEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    /// 書き込み失敗を知らせるのは1回だけ(以後は黙る。CLAUDE.md の規律)
    private var warned = false
    private var finished = false
    public let inflightURL: URL
    private let eventsDir: URL

    private init(fd: Int32, inflightURL: URL, eventsDir: URL) {
        self.fd = fd
        self.inflightURL = inflightURL
        self.eventsDir = eventsDir
    }

    /// `<runDir>/events/.inflight-<UUID>.ndjson` を開く。ディレクトリを作れない・fd を開けない
    /// ときは nil を返し、呼び出し元はログ無しで run を続ける(止めない)
    public static func start(runDir: URL) -> ScenarioEventLog? {
        let eventsDir = runDir.appendingPathComponent("events")
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let inflightURL = eventsDir.appendingPathComponent(".inflight-\(UUID().uuidString).ndjson")
        let opened = Darwin.open(inflightURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o644)
        guard opened >= 0 else {
            ConsoleOut.err("[fleetest] cannot open scenario event log at \(inflightURL.path)")
            return nil
        }
        return ScenarioEventLog(fd: opened, inflightURL: inflightURL, eventsDir: eventsDir)
    }

    // MARK: - 書き込み

    /// 子の stdout の生の1行。JSON オブジェクトとして読めれば `event` へ原文のまま埋め込む
    /// (ScenarioEvent へ再エンコードしない = 未知の欄も残る)。読めなければ `text`
    public func appendStdout(_ line: String) {
        guard !line.isEmpty else { return }
        append(encodeLine(stream: "stdout", rawLine: line))
    }

    /// 子の stderr の生の1行。**常に `text`**(stderr は NDJSON ではない)
    public func appendStderr(_ line: String) {
        guard !line.isEmpty else { return }
        append(encodeText(stream: "stderr", text: line))
    }

    /// ホストが自分で出す(子の stdout 由来でない)イベント。呼び出し元は ScenarioHost.run の
    /// abortBeforeLaunch とタイムアウト確定の2箇所だけから呼ぶこと —— 子の stdout 由来で emit
    /// されるイベントは appendStdout が既に生の行で書いているので、ここへも渡すと二重に書く
    public func appendHost(_ event: ScenarioEvent) {
        append(encodeRawEvent(stream: "host", rawEvent: event.encodedLine()))
    }

    private func encodeLine(stream: String, rawLine: String) -> String {
        if let data = rawLine.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           object is [String: Any] {
            return encodeRawEvent(stream: stream, rawEvent: rawLine)
        }
        return encodeText(stream: stream, text: rawLine)
    }

    /// rawEvent は既に妥当な JSON オブジェクトの文字列(呼び出し元が検証済み、または
    /// ScenarioEvent.encodedLine() の出力)なので、再パースせずそのまま埋め込む
    private func encodeRawEvent(stream: String, rawEvent: String) -> String {
        "{\"t\":\"\(Self.timestamp())\",\"stream\":\"\(stream)\",\"event\":\(rawEvent)}"
    }

    private func encodeText(stream: String, text: String) -> String {
        let quoted = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"(encode error)\""
        return "{\"t\":\"\(Self.timestamp())\",\"stream\":\"\(stream)\",\"text\":\(quoted)}"
    }

    /// UTC ミリ秒(`yyyy-MM-ddTHH:mm:ss.SSSZ`)。ISO8601DateFormatter はインスタンスをスレッド間で
    /// 共有しない(RunResultsStore.windowMatch と同じ規律。stdout ループと stderr の Task が並行に
    /// 呼ぶため)—— 呼ぶたびに1個作る
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func append(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        if !Self.writeAll(fd: fd, bytes: bytes), !warned {
            warned = true
            ConsoleOut.err("[fleetest] cannot write to scenario event log at \(inflightURL.path)")
        }
    }

    /// 短い write は続きを書き切る・EINTR は再試行する(ConsoleOut.emit と同じ理由)。
    /// ローカルファイルの fd なので EAGAIN/ENOBUFS は起きない想定(non-blocking にしていない)
    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var written = 0
        let total = bytes.count
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return true }
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n > 0 { written += n; continue }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    // MARK: - 確定

    /// **最後の行を書き終えてから呼ぶこと**(stderr の Task が終わる前に閉じない)。
    /// `<runDir>/events/<fileBase>.ndjson` へ rename する。呼ばれなければ
    /// `.inflight-<UUID>.ndjson` のまま残る(kill されたシナリオの証跡。消さない)。
    /// 二重に呼んでも2回目は何もしない(record() が呼ばれる経路は run() の中で高々1回)
    @discardableResult
    public func finish(fileBase: String) -> URL? {
        lock.lock()
        guard !finished else { lock.unlock(); return nil }
        finished = true
        let localFd = fd
        fd = -1
        lock.unlock()
        if localFd >= 0 { Darwin.close(localFd) }
        let finalURL = eventsDir.appendingPathComponent("\(fileBase).ndjson")
        do {
            try FileManager.default.moveItem(at: inflightURL, to: finalURL)
            return finalURL
        } catch {
            ConsoleOut.err("[fleetest] cannot finalize scenario event log "
                + "\(inflightURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
