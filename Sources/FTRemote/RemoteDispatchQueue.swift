// RemoteDispatchQueue.swift
// dispatch.lock(RemoteDispatchLock)の手前に置く **FIFO の待機チケット**。ロック本体は早い者勝ちの
// `mkdir` で、`--wait-lock` は WaitLockPolling の周期ポーリングなので、待った順は保証されない
// (後から来た run が先に取れる)。待機列は「次に取ってよいのは誰か」だけを決める ——
// **ロックの原子性は mkdir のまま**で、ここは先頭のチケットの持ち主にだけ mkdir を撃たせる。
//
// RemoteDispatchLock と同じ書き方に揃える: ①チケットの綴りの組み立て・解析 ②ssh で叩く
// 1本のコマンド文字列の組み立て ③その出力の解析、だけを行う純粋関数(結果は完全一致でテストする)。
// ssh 実行・プロセス起動・sleep はここに置かない(呼び出し側 = Sources/fleetest/RemoteRunDispatcher.swift)。

import Foundation
import FTCore

/// 待機列の1件。ファイル名そのものが全情報を持ち、**辞書順がそのまま待ち順**になる
public struct DispatchTicket: Equatable, Sendable {
    /// 待ち始めた時刻(UTC epoch ミリ秒)。**発行側が1回だけ採り、複数機械へ同じ値を運ぶ**
    /// (環境変数 `FT_DISPATCH_TICKET`)—— 機械ごとに採り直すと、同じ run の前後関係が
    /// 機械によって食い違い、フリート分担の run が機械 A では先・機械 B では後になる
    public let requestedAtMillis: Int64
    /// 自己申告の発行者(`LocalConfig.resolveIssuerId`)
    public let issuer: String
    /// 同一発行者の同時 run を区別する鍵(呼び出し側が runGroup か pid を入れる)
    public let group: String

    /// 親プロセスが子へ同じチケットを運ぶための環境変数。綴りは `fileName` と同一
    /// (2つの綴りを持たない = 片方だけ変えて順序が食い違う形を作らない)
    public static let environmentKey = "FT_DISPATCH_TICKET"

    public init(requestedAtMillis: Int64, issuer: String, group: String) {
        self.requestedAtMillis = requestedAtMillis
        self.issuer = issuer
        self.group = group
    }

    public static func now(issuer: String, group: String, date: Date = Date()) -> DispatchTicket {
        DispatchTicket(requestedAtMillis: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)),
                       issuer: issuer, group: group)
    }

    /// `<13桁ゼロ埋め epoch ミリ>~<encoded issuer>~<encoded group>`。
    /// **13桁ゼロ埋めの根拠**: epoch ミリは西暦 2286 年まで 13 桁。桁が揃っていないと辞書順が
    /// 時刻順にならない(999999999999 < 1000000000000 なのに文字列では逆)。
    /// issuer / group は英数と `@ . _ -` 以外を `%XX`(大文字16進)へ畳む(`FTCore.StreamLease.key`
    /// と同じ手法)—— **区切りの `~` も必ずエンコードされる**ので 3 分割は曖昧にならない
    public var fileName: String {
        String(format: "%013lld", requestedAtMillis)
            + "~" + Self.encodeComponent(issuer) + "~" + Self.encodeComponent(group)
    }

    public var environmentValue: String { fileName }

    /// `fileName` の逆。区切りは `~` だけ(増やさない)。壊れた名前は nil
    public static func parse(fileName: String) -> DispatchTicket? {
        let parts = fileName.split(separator: "~", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let stamp = parts[0]
        guard !stamp.isEmpty, stamp.allSatisfy({ $0.isASCII && $0.isNumber }),
              let millis = Int64(stamp),
              let issuer = decodeComponent(parts[1]), let group = decodeComponent(parts[2])
        else { return nil }
        return DispatchTicket(requestedAtMillis: millis, issuer: issuer, group: group)
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DispatchTicket? {
        environment[environmentKey].flatMap { parse(fileName: $0) }
    }

    private static func encodeComponent(_ text: String) -> String {
        var encoded = ""
        for byte in Array(text.utf8) {
            let scalar = UnicodeScalar(byte)
            let safe = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || scalar == "@" || scalar == "." || scalar == "_" || scalar == "-"
            encoded += safe ? String(Character(scalar)) : String(format: "%%%02X", byte)
        }
        return encoded
    }

    /// `%XX` を1バイトへ戻す。`UInt8(_:radix:)` は符号を受けるので(`%+1` が通る)、
    /// 16進2桁であることを先に確かめる
    private static func decodeComponent(_ text: Substring) -> String? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "%" {
                let hexStart = text.index(after: index)
                guard let hexEnd = text.index(hexStart, offsetBy: 2, limitedBy: text.endIndex) else {
                    return nil
                }
                let hex = text[hexStart..<hexEnd]
                guard hex.allSatisfy({ $0.isHexDigit }), let byte = UInt8(hex, radix: 16) else {
                    return nil
                }
                bytes.append(byte)
                index = hexEnd
            } else {
                guard let ascii = character.asciiValue else { return nil }
                bytes.append(ascii)
                index = text.index(after: index)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// 待機列の置き場・コマンド・出力解析(純粋関数)
public enum RemoteDispatchQueue {

    /// **機械に1本**(発行者ネームスペースの中にも `<base>` の中にも置かない = 他人の待機が
    /// 見えないと順番が成立しない。置き場が `$HOME`(`FTCore.MachineStateDirectory`)である
    /// 理由はロック本体と同じ —— `RemoteDispatchLock.lockDirPath`)
    public static func directory(home: String) -> String {
        MachineStateDirectory.path(home: home) + "/dispatch.queue"
    }

    public static func ticketFilePath(home: String, ticket: DispatchTicket) -> String {
        directory(home: home) + "/" + ticket.fileName
    }

    /// 待機チケットの失効(秒)。**待っている側は `WaitLockPolling.pollIntervalSeconds`(10秒)ごとに
    /// 自分のチケットを書き直す(= mtime の touch)ので、その3倍を過ぎたものは書き手が死んだと見なす**
    /// (ポーリング1回ぶんの遅れ・ssh の詰まりでは失効しない余裕)。`WaitLockPolling` を変えたら
    /// ここも動かす(`RemoteDispatchQueueTests` が 3 倍の関係を固定)。
    ///
    /// **ここが唯一 mtime に頼る場所**(CLAUDE.md の「生存判定は pid だけ・mtime を見ない」は同じ
    /// 機械の中の話)—— `RemoteDispatchLockInfo.pid` が表示専用なのと同じ理由で、**発行側の pid は
    /// ランナーから見えない**ので生存判定に使えない。**失効しても run は1本も殺さない**
    /// (待機列から落ちて順番を失うだけ。ロック本体には時刻判定を一切入れない =
    /// docs/remote-runner.md §5「既定では奪わない」)
    public static let staleSeconds = 30

    // MARK: - ssh コマンド組み立て(1往復・純粋関数)

    private static let queueHeader = "QUEUE"
    private static let sectionSeparator = "---"
    private static let acquiredWord = "ACQUIRED"
    private static let heldWord = "HELD"
    private static let waitingWord = "WAITING"

    /// 並んで、先頭なら取る、を1往復で行う。出力の契約は `parseOutcome`(下)。
    ///
    /// **グロブを書かない**(相手は zsh。マッチしないグロブは `for` の語リストならシェルごと落ちる)
    /// ので一覧は `find` で作る。`sed`/`printf` の中の `*`・`%` はシングルクォートの内側なので
    /// シェルは触らない。
    /// ロックの取得(`mkdir` の原子性・info.json の書き方)は `RemoteDispatchLock.acquireCommand`
    /// をそのまま使う —— **同じ綴りを2箇所に持たない**(leaf の `mkdir` に `-p` が無いのがロックの実体)
    public static func enqueueAndTryAcquireCommand(home: String, ticket: DispatchTicket,
                                                   info: RemoteDispatchLockInfo) -> String {
        let dir = RemoteShell.quote(directory(home: home))
        let ticketPath = RemoteShell.quote(ticketFilePath(home: home, ticket: ticket))
        // `mkdir -p` は `.fleetest` ごと作る(親だけ別に作らない)
        let enqueue = "mkdir -p \(dir) && printf '%s' 'queued' > \(ticketPath) || exit 1"
        // 失効した控えを掃く。自分のは今書いたので残る
        let sweepStale = "find \(dir) -type f ! -newermt"
            + " \(RemoteShell.quote("-\(staleSeconds) seconds")) -delete 2>/dev/null"
        // 生きているチケットの**ファイル名だけ**を辞書順で。1回だけ採って変数に置く
        // (印字と先頭判定が別の一覧になると、Swift 側の position と判定語が食い違う)
        let list = "q=$(find \(dir) -type f 2>/dev/null | sed 's|.*/||' | sort)"
        let iAmFirst = "[ \"$(printf '%s\\n' \"$q\" | head -n 1)\" = \(RemoteShell.quote(ticket.fileName)) ]"
        return enqueue + "; " + sweepStale + "; " + list + "; "
            + emit(queueHeader) + "; printf '%s\\n' \"$q\"; " + emit(sectionSeparator) + "; "
            + "if \(iAmFirst); then"
            + " if \(RemoteDispatchLock.acquireCommand(home: home, info: info)); then"
            + " rm -f \(ticketPath); \(emit(acquiredWord));"
            + " else \(emit(heldWord)); fi;"
            + " else \(emit(waitingWord)); fi; "
            + emit(sectionSeparator) + "; " + RemoteDispatchLock.readCommand(home: home)
    }

    /// 待つのをやめた/失敗したときに**自分のチケットだけ**を消す(他人の待機には触らない)
    public static func dequeueCommand(home: String, ticket: DispatchTicket) -> String {
        "rm -f \(RemoteShell.quote(ticketFilePath(home: home, ticket: ticket)))"
    }

    /// 印の1行。`echo` を使わない(`---` は zsh の echo ではオプション扱いになりうる)
    private static func emit(_ word: String) -> String {
        "printf '%s\\n' \(RemoteShell.quote(word))"
    }

    // MARK: - 出力の解析

    public enum Outcome: Equatable, Sendable {
        /// ロックを取れた(自分のチケットは向こうで消えている)
        case acquired
        /// 自分より前に待っている人が居る。position は1始まり、total は生きているチケットの数
        case waiting(position: Int, total: Int, holder: RemoteDispatchLockInfo?)
        /// 先頭なのにロックが取れなかった(保持者が居る)
        case held(position: Int, total: Int, holder: RemoteDispatchLockInfo?)
    }

    /// `enqueueAndTryAcquireCommand` の出力を読む。**position / total の算出はここ(Swift 側)**
    /// —— シェルに判定を増やさない(判定は1箇所)。
    /// `waiting` / `held` で**自分のチケットが一覧に無い**出力は nil(解析不能。呼び出し側は
    /// 従来のエラー経路へ倒す)。`acquired` は一覧を見ない —— ロックは既に取れており、
    /// 判定語のほうが一覧より新しい事実
    public static func parseOutcome(_ output: String, ticket: DispatchTicket) -> Outcome? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let header = lines.firstIndex(of: queueHeader),
              let firstSeparator = lines[header...].firstIndex(of: sectionSeparator),
              let verdictIndex = lines[(firstSeparator + 1)...].firstIndex(where: { !$0.isEmpty }),
              let secondSeparator = lines[(verdictIndex + 1)...].firstIndex(of: sectionSeparator)
        else { return nil }

        let names = lines[(header + 1)..<firstSeparator].filter { !$0.isEmpty }
        let holder = RemoteDispatchLock.decode(lines[(secondSeparator + 1)...].joined(separator: "\n"))

        switch lines[verdictIndex] {
        case acquiredWord:
            return .acquired
        case heldWord, waitingWord:
            guard let mine = names.firstIndex(of: ticket.fileName) else { return nil }
            let position = mine + 1
            return lines[verdictIndex] == heldWord
                ? .held(position: position, total: names.count, holder: holder)
                : .waiting(position: position, total: names.count, holder: holder)
        default:
            return nil
        }
    }
}
