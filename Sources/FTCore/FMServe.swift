// FM の常駐プロセス(`fleetest api fm-serve`)との通信と起動。**画像を伴う FM の呼び出し(テキストの可視性検証・
// screenLooksLike・死活の確かめ)は全部この1プロセスが撃つ**。シナリオのプロセスは LanguageModelSession を持たない。
//
// なぜ常駐の1プロセスか(実測・docs/maintainer-notes.md §81): FM の死(ANE の `Program load failed — no memory`)は
// 「使っていない間に降ろされたモデルを ANE に載せ直す瞬間」に起きる。OS は最後の利用から約 4 秒で FM の部品を降ろす。
// 入れ替わる多数のシナリオのプロセスが各自セッションを作る形では、載せ直しが絶えず起きる。1 プロセスが撃ち続けた
// 計測(デバイス実行の横で 528 回・デバイス無しで 1,000 回超)では一度も死ななかった。
// 常駐プロセスは載せたままにする暖機(`FMServeServer` の keep-warm)を持ち、run の後もしばらく生きる。
//
// 寿命: **run の子ではない**(`FT_PARENT_PID` を渡さない = 親の死で終わらない・拡張の孤児掃除の対象外)。どこからも
// 要求が無い時間が `FMServeWire.idleExitSeconds` を超えたら自分で終わる。同じソケットに生きた相手が居れば2つ目は起きない。
// 同期相手: サーバは Sources/FTFoundationModels/FMServeServer.swift・コマンドは Sources/fleetest/ApiFMServeCommand.swift。

import CoreGraphics
import Foundation
import Synchronization

public enum FMServeWire {
    /// 要求・応答の形の版。欄や意味を変えたら +1。不一致は推論を拒否し、置換には安全な退役の受諾を要する。
    public static let protocolVersion = 4
    // 引継ぎ制御は推論の版と独立。相手の版を偽装せず、将来の新版からも同じ安全な停止を頼める。
    public static let retirementProtocolVersion = 1
    /// 安全退役(retire)を初めて実装した推論契約の版。
    public static let minimumRetirementServerVersion = 4

    /// シナリオのプロセスへソケットのパスを渡す環境変数(`ScenarioHost.childEnvironment` が載せる)
    public static let socketEnvironmentKey = "FT_FM_SERVE_SOCKET"

    /// 1 要求の期限[秒]。生きた FM の1回は 0.7〜4.7 秒(実測)。ANE が「no memory」で死んだ機械では respond が
    /// 戻らない(実測: ft_status が 2 分以上止まった)ので期限が要る。その 4 倍強(`FMLivenessProbe` の旧い期限と同じ値)。
    /// **尽きたとき**: サーバはその要求を `failed`(期限切れ)で返す。クライアントはサーバより少し長く待つ(`clientDeadlineSeconds`)
    public static let requestDeadlineSeconds: Double = 20

    /// クライアントの待ちの上限[秒]。サーバの期限 + 接続・書き込み・読み込みの余裕 5 秒
    /// (サーバの期限切れの応答を受け取れるだけ長く = クライアントが先に諦めて「繋がらない」と取り違えない)
    public static let clientDeadlineSeconds: Double = requestDeadlineSeconds + 5

    /// どこからも要求(状態の問い合わせを除く)が無いまま、この秒数が過ぎたら常駐プロセスは終わる。
    /// **根拠は実測ではなく方針**: run の後も同じ作業の続き(次の run・MCP の確認)ではモデルを載せたままにしたい
    /// (載せ直しが FM の死の引き金)。一方で使わない Mac に ANE を一日中占有させない。拡張のモニターを開いている間は
    /// 死活の確かめ(毎分)が要求になるので終わらない。**尽きたとき**: 終わる。次に要る経路が起こし直す(載せ直しが 1 回起きる)
    public static let idleExitSeconds: Double = 30 * 60

    /// `~/.fleetest/fm.sock`(機械に1つ)。sun_path に収まらなければ nil(常駐プロセスを起こさない = FM を使わない)
    public static func socketPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = MachineStateDirectory.url(home: home).appendingPathComponent("fm.sock").path
        return FramedUnixSocket.fitsSunPath(path) ? path : nil
    }

    public enum Kind: String, Codable, Sendable {
        /// 切り出した画像に描かれた文字の転写(テキストの可視性検証)。`png` が要る
        case transcribe
        /// 画面が期待の状態に合うか(screenLooksLike)。`png` と `expected` が要る
        case screen
        /// 死活の確かめ(実呼び出し 1 回)。`path` が要る
        case probe
        /// 版と実行ファイルの問い合わせ(FM は呼ばない・寿命を延ばさない)
        case status
        /// 旧制御。新版は呼び手の版を確認できない停止要求を拒否し、RetirementRequestだけを受け入れる。
        case shutdown
    }

    public struct Request: Codable, Sendable, Equatable {
        public var version: Int
        public var kind: Kind
        public var png: Data?
        public var expected: String?
        public var path: FMLiveness.Path?
        public init(kind: Kind, png: Data? = nil, expected: String? = nil, path: FMLiveness.Path? = nil,
                    version: Int = FMServeWire.protocolVersion) {
            self.version = version
            self.kind = kind
            self.png = png
            self.expected = expected
            self.path = path
        }
    }

    public enum Status: String, Codable, Sendable {
        case ok
        /// FM が答えなかった(`error` に FMHealth.describe 済みの連鎖)・要求が壊れている
        case failed
        /// 安全判定による拒否は失敗に数えない。同じ画面での拒否の連続を「死」と誤認するため。
        case refused
        /// 要求の版がサーバと違う(何もしていない)
        case versionMismatch
    }

    /// status / shutdown の固定契約。推論結果の必須欄が増えても、置換対象の身元を読める形を保つ。
    public struct Identity: Codable, Sendable, Equatable {
        public var status: Status
        public var serverVersion: Int
        public var executable: String
        public var buildStamp: String

        public init(status: Status, serverVersion: Int = FMServeWire.protocolVersion,
                    executable: String, buildStamp: String) {
            self.status = status
            self.serverVersion = serverVersion
            self.executable = executable
            self.buildStamp = buildStamp
        }
    }

    public struct Response: Codable, Sendable, Equatable {
        public typealias Status = FMServeWire.Status
        public var status: Status
        /// transcribe の転写
        public var text: String?
        /// screen の判定
        public var pass: Bool?
        public var reason: String?
        public var error: String?
        /// 実際に開始した追加試行数(0 / 1)。期限切れ・拒否でも失わない。
        public var retryCount: Int
        /// サーバの版・実行ファイル(置き換えの判断に使う)
        public var serverVersion: Int
        public var executable: String
        public var buildStamp: String
        public init(status: Status, text: String? = nil, pass: Bool? = nil, reason: String? = nil, error: String? = nil,
                    retryCount: Int = 0,
                    serverVersion: Int = FMServeWire.protocolVersion, executable: String, buildStamp: String) {
            self.status = status
            self.text = text
            self.pass = pass
            self.reason = reason
            self.error = error
            self.retryCount = retryCount
            self.serverVersion = serverVersion
            self.executable = executable
            self.buildStamp = buildStamp
        }
    }

    public struct RetirementRequest: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case retire }
        public var kind: Kind
        public var controlVersion: Int
        public var target: Identity
        public var replacementVersion: Int

        public init(target: Identity, replacementVersion: Int = FMServeWire.protocolVersion,
                    controlVersion: Int = FMServeWire.retirementProtocolVersion) {
            kind = .retire
            self.controlVersion = controlVersion
            self.target = target
            self.replacementVersion = replacementVersion
        }
    }

    public struct RetirementResponse: Codable, Sendable, Equatable {
        public enum Outcome: String, Codable, Sendable {
            case retiring, busy, identityMismatch, newerServer, unsupported
        }
        public var controlVersion: Int
        public var identity: Identity
        public var outcome: Outcome

        public init(controlVersion: Int = FMServeWire.retirementProtocolVersion,
                    identity: Identity, outcome: Outcome) {
            self.controlVersion = controlVersion
            self.identity = identity
            self.outcome = outcome
        }
    }

    /// 実行ファイルの版の印(変更時刻と大きさ)。作り直した `fleetest` は別の印になる。読めなければ空
    public static func buildStamp(executable: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: executable),
              let date = attrs[.modificationDate] as? Date, let size = attrs[.size] as? NSNumber else { return "" }
        return "\(Int(date.timeIntervalSince1970))-\(size.intValue)"
    }
}

public enum FMServeError: Error, CustomStringConvertible {
    /// 常駐プロセスに届かない(起こしていない・死んだ・答えない)。**FM の失敗ではない**
    case unavailable(String)

    public var description: String {
        switch self {
        case .unavailable(let detail): return "the FM process (fleetest api fm-serve) is unavailable (\(detail))"
        }
    }
}

/// 常駐プロセスへ 1 要求を送る(要求ごとに接続して使い切る)
public struct FMServeClient: Sendable {
    public let socketPath: String
    public var deadlineSeconds: Double

    public init(socketPath: String, deadlineSeconds: Double = FMServeWire.clientDeadlineSeconds) {
        self.socketPath = socketPath
        self.deadlineSeconds = deadlineSeconds
    }

    /// シナリオのプロセスの入口。環境変数が無い(= run が常駐プロセスを用意していない)なら nil
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> FMServeClient? {
        guard let path = environment[FMServeWire.socketEnvironmentKey], !path.isEmpty else { return nil }
        return FMServeClient(socketPath: path)
    }

    /// 要求に載せる PNG(Vision の補助と同じ変換)
    public static func pngData(_ image: CGImage) -> Data? { VisionHelperClient.pngData(image) }

    /// 届かなければ `FMServeError.unavailable`。届いたら応答をそのまま返す(`failed` の扱いは呼び手)
    public func send(_ request: FMServeWire.Request) async throws -> FMServeWire.Response {
        let payload = try await exchange(request)
        do {
            return try JSONDecoder().decode(FMServeWire.Response.self, from: payload)
        } catch {
            throw FMServeError.unavailable("the answer could not be decoded: \(error)")
        }
    }

    public func status() async throws -> FMServeWire.Identity {
        try await control(FMServeWire.Request(kind: .status))
    }

    /// 旧常駐の手動保守用。wire4以降は呼び手の版を検証できないため拒否される。自動更新はretireを使う。
    public func shutdown(serverVersion: Int) async throws -> FMServeWire.Identity {
        try await control(FMServeWire.Request(kind: .shutdown, version: serverVersion))
    }

    public func retire(_ request: FMServeWire.RetirementRequest) async throws -> FMServeWire.RetirementResponse {
        let payload = try await exchange(request)
        return try JSONDecoder().decode(FMServeWire.RetirementResponse.self, from: payload)
    }

    func waitForRetirement(target: FMServeWire.Identity, waitSeconds: Double) async throws -> FMServeWire.RetirementResponse {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, waitSeconds)))
        while true {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                return FMServeWire.RetirementResponse(identity: target, outcome: .busy)
            }
            var attempt = self
            attempt.deadlineSeconds = min(deadlineSeconds,
                Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
            let response = try await attempt.retire(FMServeWire.RetirementRequest(target: target))
            guard response.controlVersion == FMServeWire.retirementProtocolVersion,
                  response.identity.serverVersion == target.serverVersion,
                  response.identity.executable == target.executable,
                  response.identity.buildStamp == target.buildStamp,
                  response.outcome == .busy else { return response }
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return response }
            // 暖機終了後の1秒の隙間を照会する。照会はFM推論を起こさず、毎秒10回を上限とする。
            try await Task.sleep(for: min(.milliseconds(100), left))
        }
    }

    private func control(_ request: FMServeWire.Request) async throws -> FMServeWire.Identity {
        let payload = try await exchange(request)
        do {
            return try JSONDecoder().decode(FMServeWire.Identity.self, from: payload)
        } catch {
            throw FMServeError.unavailable("the identity could not be decoded: \(error)")
        }
    }

    private func exchange(_ request: some Encodable) async throws -> Data {
        let payload: Data
        do {
            let frame = try FramedUnixSocket.encode(request)
            payload = try await FramedUnixSocket.exchangeAsync(path: socketPath, frame: frame, seconds: deadlineSeconds)
        } catch let failure as FramedUnixSocketError {
            throw FMServeError.unavailable(failure.description)
        }
        return payload
    }
}

/// 常駐プロセスを用意する側(run・死活の確かめ・doctor)。シナリオのプロセスはここを使わない(枠の中から起こせない)
public enum FMServeHost {
    private static let active = Mutex<String?>(nil)

    /// このプロセスが用意した常駐プロセスのソケット(`ScenarioHost.childEnvironment` とサンドボックスの許可が読む)
    public static var activeSocketPath: String? { active.withLock { $0 } }

    /// その run で FM を使う機能が有効か(テキストの可視性検証の FM の段か screenLooksLike)
    public static func needed(fmTextVisibilityCheck: Bool, screenLooksLike: Bool) -> Bool {
        fmTextVisibilityCheck || screenLooksLike
    }

    /// 起こす実行ファイル: このプロセスと同じディレクトリの `fleetest`(`fleetest-mcp` からも同じ物を指す)。
    /// テスト(xctest)など fleetest の隣に居ないプロセスからは起こさない
    static func serverExecutable(current: URL? = ExecutablePath.current) -> URL? {
        guard let current, ["fleetest", "fleetest-mcp"].contains(current.lastPathComponent) else { return nil }
        let sibling = current.deletingLastPathComponent().appendingPathComponent("fleetest")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// 生きている常駐プロセスをどう扱うか
    enum LiveServerDecision: Equatable {
        enum LeaveReason: Equatable {
            case versionMismatch, unsupportedRetirement, retirementRejected, busy, retirementQueryFailed, cancelled
        }
        /// そのまま使う
        case reuse
        /// 止めて起こし直す(相手が自分の実行ファイルより古い)
        case replace
        /// 使えないが止めない(古いのはこちら / 版の違う別のクローンの常駐プロセス)= この経路では FM を使わない
        case leave(LeaveReason)
    }

    /// 判断(純粋関数)。`executable` / `buildStamp` はこちらの実行ファイルとディスク上の今の印、`serverExecutableStamp` は
    /// 相手の実行ファイルのディスク上の今の印。**止めるのは「相手が自分の実行ファイルより古い」ときだけ** ——
    /// 作り直す前から生きているプロセス(拡張の host-metrics)は、ディスク上の新しい版の常駐プロセスを「版が違う」と見て
    /// 止めてしまい、毎分の死活の確かめのたびに入れ替え(= 載せ直し)を起こした。別のクローン同士も止め合わない
    static func decide(_ status: FMServeWire.Identity, executable: String, buildStamp: String,
                       serverExecutableStamp: String) -> LiveServerDecision {
        guard status.serverVersion <= FMServeWire.protocolVersion else { return .leave(.versionMismatch) }
        let sameVersion = status.serverVersion == FMServeWire.protocolVersion
        // 印が読めない(空 = 実行ファイルの属性が取れなかった。リンクの作り直しの瞬間など)は「古い」と言える根拠が無い ——
        // 止めずに版だけで決める(読めないことを「違う」に畳むと、正常な常駐プロセスを止めて FM の載せ直しを起こす)
        if buildStamp.isEmpty || serverExecutableStamp.isEmpty || status.buildStamp.isEmpty {
            return sameVersion ? .reuse : .leave(.versionMismatch)
        }
        if status.executable == executable {
            if status.buildStamp != buildStamp { return .replace }   // 相手は作り直す前の版
            return sameVersion ? .reuse : .leave(.versionMismatch)     // 同じ版のはずが違う = 古いのはこちら
        }
        if status.buildStamp != serverExecutableStamp { return .replace }   // 相手は自分の実行ファイルより古い
        return sameVersion ? .reuse : .leave(.versionMismatch)
    }

    static func prepareExistingServer(_ status: FMServeWire.Identity, client: FMServeClient,
                                      executable: String, buildStamp: String,
                                      serverExecutableStamp: String,
                                      waitSeconds: Double = retirementWaitSeconds) async -> LiveServerDecision {
        let decision = decide(status, executable: executable, buildStamp: buildStamp,
                              serverExecutableStamp: serverExecutableStamp)
        if decision == .replace {
            guard status.serverVersion >= FMServeWire.minimumRetirementServerVersion else {
                return .leave(.unsupportedRetirement)
            }
            do {
                let response = try await client.waitForRetirement(target: status, waitSeconds: waitSeconds)
                guard response.controlVersion == FMServeWire.retirementProtocolVersion,
                      response.identity.serverVersion == status.serverVersion,
                      response.identity.executable == status.executable,
                      response.identity.buildStamp == status.buildStamp else { return .leave(.retirementRejected) }
                switch response.outcome {
                case .retiring: return .replace
                case .busy: return .leave(.busy)
                case .identityMismatch, .newerServer, .unsupported: return .leave(.retirementRejected)
                }
            } catch {
                return .leave(Task.isCancelled || error is CancellationError ? .cancelled : .retirementQueryFailed)
            }
        }
        return decision
    }

    /// 暖機の応答期限20秒＋制御の余裕5秒(既存のクライアント予算)だけ待つ。
    /// 非協調な推論が残る場合も延長せず、尽きたら停止せずleaveしてFMのスキップ理由を表示する。
    static let retirementWaitSeconds: Double = FMServeWire.clientDeadlineSeconds

    /// 起こしてから状態の問い合わせに答えるまで待つ上限[秒]。答えるのは bind の直後(FM の積み込みは待たない)なので
    /// 起動の所要(実測 0.1〜0.3 秒)の桁上。**尽きたとき**: nil = この run では FM を使わない(1 行言う)
    static let startupWaitSeconds: Double = 5

    /// 常駐プロセスを用意して、そのソケットのパスを返す。用意できなければ nil(理由は `log` へ 1 行)
    @discardableResult
    public static func ensureRunning(log: (String) -> Void) async -> String? {
        guard let path = FMServeWire.socketPath() else { log("⚠️ FM process not started: the socket path does not fit"); return nil }
        guard let executable = serverExecutable() else { return nil }
        let stamp = FMServeWire.buildStamp(executable: executable.path)
        let client = FMServeClient(socketPath: path, deadlineSeconds: 3)
        return await ensureRunning(client: client, executable: executable, stamp: stamp,
                                   initialStatus: try? await client.status(), log: log)
    }

    static func ensureRunning(client: FMServeClient, executable: URL, stamp: String,
                              initialStatus: FMServeWire.Identity?,
                              waitSeconds: Double = retirementWaitSeconds,
                              spawn: (URL, String) -> Bool = FMServeHost.spawn,
                              log: (String) -> Void) async -> String? {
        let path = client.socketPath
        guard !Task.isCancelled else { return nil }
        if let status = initialStatus {
            switch await prepareExistingServer(status, client: client, executable: executable.path, buildStamp: stamp,
                                              serverExecutableStamp: FMServeWire.buildStamp(executable: status.executable),
                                              waitSeconds: waitSeconds) {
            case .reuse:
                active.withLock { $0 = path }
                return path
            case .leave(.retirementQueryFailed):
                // 別の呼び手が退役させた場合、例外だけでは生存も終了も言えない。身元と所有権を読み直す。
                if let current = try? await client.status() {
                    if current.status == .ok,
                       decide(current, executable: executable.path, buildStamp: stamp,
                              serverExecutableStamp: FMServeWire.buildStamp(executable: current.executable)) == .reuse {
                        active.withLock { $0 = path }
                        return path
                    }
                } else if !Task.isCancelled {
                    break
                }
                log("⚠️ FM retirement query failed; neither a usable FM process nor a released socket could be confirmed;"
                    + " FM checks are skipped here")
                return nil
            case .leave(.busy):
                log("⚠️ The FM process stayed busy for \(Int(waitSeconds)) s; it was left running; FM checks are skipped here")
                return nil
            case .leave(.cancelled):
                log("⚠️ FM process setup was cancelled; no replacement was started")
                return nil
            case .leave(.versionMismatch), .leave(.unsupportedRetirement), .leave(.retirementRejected):
                log("⚠️ FM process (\(status.executable)) speaks protocol \(status.serverVersion), this process"
                    + " \(FMServeWire.protocolVersion); it was left running because safe reuse or retirement could not"
                    + " be confirmed; FM checks are skipped here (align the FM process and its callers)")
                return nil
            case .replace:
                break
            }
            // 置き換え: 前の常駐プロセスがソケットを離すまで待つ
            let until = Date().addingTimeInterval(startupWaitSeconds)
            while !FramedUnixSocket.isReleased(path: path), Date() < until {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard FramedUnixSocket.isReleased(path: path) else {
                log("⚠️ The retiring FM process has not released its socket; FM checks are skipped here")
                return nil
            }
        }
        guard !Task.isCancelled else { return nil }
        guard spawn(executable, path) else {
            log("⚠️ FM process could not be started; FM checks are skipped in this run")
            return nil
        }
        let until = Date().addingTimeInterval(startupWaitSeconds)
        while Date() < until {
            if let status = try? await client.status(), status.status == .ok,
               status.serverVersion == FMServeWire.protocolVersion {
                active.withLock { $0 = path }
                return path
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("⚠️ FM process did not answer within \(Int(startupWaitSeconds))s; FM checks are skipped in this run")
        return nil
    }

    /// 子の環境: **`FT_PARENT_PID` を消す**(渡すと親の死で終わり、拡張の孤児掃除にも殺される = 常駐にならない)。
    /// 起こした run の環境の FM のソケットも消す(自分自身を指す値は要らない)
    static func serverEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env[ParentDeathWatch.environmentKey] = nil
        env[FMServeWire.socketEnvironmentKey] = nil
        env[DispatchRefusalReport.environmentKey] = nil
        return env
    }

    static func spawn(executable: URL, socketPath: String) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["api", "fm-serve", "--socket", socketPath]
        process.environment = serverEnvironment()
        process.standardInput = FileHandle.nullDevice
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/fleetest/fm-serve.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let sink = (try? FileHandle(forWritingTo: logURL)).map { handle -> FileHandle in
            handle.seekToEndOfFile()
            return handle
        }
        process.standardOutput = sink ?? FileHandle.nullDevice
        process.standardError = sink ?? FileHandle.nullDevice
        process.qualityOfService = .utility
        defer { try? sink?.close() }   // 子は自分の複製を持つ。親の分は閉じる(起こすたびに fd を残さない)
        do {
            try process.run()
        } catch {
            return false
        }
        // 親は待たない(常駐 = 親より長く生きる)。Process の子はプロセスグループの長なので端末の Ctrl-C も届かない
        return true
    }
}
