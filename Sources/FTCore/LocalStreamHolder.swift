// LocalStreamHolder.swift
// **同じ Mac で同じ台の画面配信を二重に張らない**ための判定(手元版)。VSCode のウィンドウを2つ
// 開くと拡張ホストが2つ立ち、それぞれが監視(`api monitor`)と配信ヘルパー(`fleetest-simstream` /
// `fleetest-androidstream` / `fleetest-devicepoll`)を起こすので、同じ台に配信が2本重なる
// (端末側の捕捉コストが2倍。Android は配信の重なりで run が赤になった実測がある。docs/verification.md)。
//
// リモート(共有ランナー)の同型は `StreamLease`(台帳 + 発行者)だが、手元は**台帳を置かず
// プロセスの実体で判定する** —— 拡張はヘルパーを直接 spawn する(`api device-stream` を通らない)ので
// 控えを書く口が無く、ヘルパーの環境には所有の印 `FT_PARENT_PID`(= 拡張ホストの pid)が既にある。
// `ps -E` で見える command + env から「その台のヘルパーを誰が持っているか」を読む。
//
// 規律3つ:
//   ① **拒否しない・殺さない**。監視が `streamedByOther` を配り、拡張がその台の配信を起こさない /
//      畳むだけ(リモート版と同じ形。拡張側は monitorDeviceStreamController.ts)
//   ② **保持者は1本に決まる**(両方のウィンドウが同じ答えを出す): 同じ台のヘルパーが複数居たら
//      **最も早く起動したもの**(etime が最大。同点は pid が小さいほう)を保持者とする。
//      両方が「相手が保持者」と読んで両方畳む形にならない
//   ③ **自分のヘルパーは自分のもの**: 保持者の `FT_PARENT_PID` が自分の `FT_PARENT_PID` と同じなら
//      false。どちらかが無い(手で起こしたヘルパー / CLI の監視)場合は別人として扱う =
//      手で `nohup` した配信が居る台に拡張は重ねない
//
// **iOS 実機の devicepoll はブリッジのポートで台を識別する**(udid を持たない)。ポートは
// 供給のたびに変わりうるが、監視が同じ周期で同じ状態から引くので綴りは一致する。

import Foundation

public enum LocalStreamHolder {

    /// `ps -E` の1行(pid / 起動からの経過秒 / command と env のトークン列)
    public struct ProcessRow: Equatable, Sendable {
        public let pid: Int32
        public let elapsedSeconds: Int
        public let tokens: [String]

        public init(pid: Int32, elapsedSeconds: Int, tokens: [String]) {
            self.pid = pid
            self.elapsedSeconds = elapsedSeconds
            self.tokens = tokens
        }

        /// 環境の所有の印(`FT_PARENT_PID=<n>`)。無ければ nil
        public var owner: Int32? {
            for token in tokens where token.hasPrefix(ParentDeathWatch.environmentKey + "=") {
                return Int32(token.dropFirst(ParentDeathWatch.environmentKey.count + 1))
            }
            return nil
        }
    }

    /// 台の識別(拡張・`api device-stream` が起こすヘルパーの引数と同じ綴り。
    /// 契約: vscode-fleetest/src/monitorDeviceStreamController.ts / ApiDeviceStreamCommand.helperArgv)
    public enum DeviceIdentity: Equatable, Sendable {
        case iosSimulator(udid: String)
        case iosPhysical(port: UInt16)
        case android(serial: String)

        /// (ヘルパー名, 識別フラグ, 値)。androidstream(仮想)と devicepoll(実機)は同じ
        /// `--serial` を取るので Android は両方のヘルパー名を許す
        var matchers: [(helper: String, flag: String, value: String)] {
            switch self {
            case .iosSimulator(let udid):
                return [("fleetest-simstream", "--udid", udid)]
            case .iosPhysical(let port):
                return [("fleetest-devicepoll", "--port", String(port))]
            case .android(let serial):
                return [("fleetest-androidstream", "--serial", serial),
                        ("fleetest-devicepoll", "--serial", serial)]
            }
        }
    }

    /// その台を捕捉しているヘルパーの行(識別フラグの直後の値が一致するもの)
    public static func helpers(for identity: DeviceIdentity, in rows: [ProcessRow]) -> [ProcessRow] {
        rows.filter { row in
            guard let program = row.tokens.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else {
                return false
            }
            return identity.matchers.contains { matcher in
                guard program == matcher.helper,
                      let index = row.tokens.firstIndex(of: matcher.flag),
                      index + 1 < row.tokens.count else { return false }
                return row.tokens[index + 1] == matcher.value
            }
        }
    }

    /// 保持者(規律②)。居なければ nil
    public static func holder(for identity: DeviceIdentity, in rows: [ProcessRow]) -> ProcessRow? {
        helpers(for: identity, in: rows).min { a, b in
            if a.elapsedSeconds != b.elapsedSeconds { return a.elapsedSeconds > b.elapsedSeconds }
            return a.pid < b.pid
        }
    }

    /// **他のウィンドウ(別の所有者)がこの台を配信中か**(規律③)。純粋関数
    public static func heldByOther(identity: DeviceIdentity, rows: [ProcessRow], myOwner: Int32?) -> Bool {
        guard let holder = holder(for: identity, in: rows) else { return false }
        guard let mine = myOwner, let theirs = holder.owner else { return true }
        return mine != theirs
    }

    // MARK: - ps の読み

    /// `ps -E -ww -axo pid=,etime=,command=` の出力を行ごとに読む。読めない行は捨てる
    public static func parse(psOutput: String) -> [ProcessRow] {
        psOutput.split(separator: "\n").compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 3, let pid = Int32(tokens[0]),
                  let elapsed = elapsedSeconds(etime: tokens[1]) else { return nil }
            return ProcessRow(pid: pid, elapsedSeconds: elapsed, tokens: Array(tokens.dropFirst(2)))
        }
    }

    /// `etime` の書式 `[[dd-]hh:]mm:ss` を秒へ
    public static func elapsedSeconds(etime: String) -> Int? {
        var days = 0
        var rest = Substring(etime)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Int(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { $0 }
        let (hours, minutes, seconds) = values.count == 3
            ? (values[0], values[1], values[2]) : (0, values[0], values[1])
        return ((days * 24 + hours) * 60 + minutes) * 60 + seconds
    }

    /// いま動いている全プロセス(env 付き)。`ps` が失敗したら空 = 誰も持っていない側に倒す
    /// (配信を起こさない誤りより、二重を1周期見逃す誤りのほうが軽い。次の周期で拾う)
    public static func snapshot() -> [ProcessRow] {
        guard let result = try? Shell.run(["ps", "-E", "-ww", "-axo", "pid=,etime=,command="], timeout: 10),
              result.status == 0 else { return [] }
        return parse(psOutput: result.output)
    }

    /// 自分の所有の印(監視を起こした拡張ホストの pid)。無ければ nil = 誰のヘルパーも別人
    public static func myOwner(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32? {
        environment[ParentDeathWatch.environmentKey].flatMap(Int32.init)
    }
}
