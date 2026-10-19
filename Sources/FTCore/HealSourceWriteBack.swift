// 自己修復の修正提案を run の終わりにシナリオのソースへ書き戻す(ファイルの読み書きとロック)。
// 計画と置換は `HealWriteBack`(純粋)。呼ぶのは結果を受け取った側だけ:
// `fleetest run`(プロファイル有り・無し)/ `fleetest api run` / リモートの回収後(`RemoteRunDispatcher`)/
// MCP の `ft_run_scenario`(プロセス内で回すので run の経路を通らない)。
// ランナー機で走る子(`HealWriteBack.dispatchedRunEnvironmentKey`)と dry-run は呼ばない。
// 分割した run(`--fleet` / 複数の機械にまたがるプロファイル)の子は書かずに親へ渡し(`HealWriteBack.collectEnvironmentKey`)、
// 親が `Collection.finish` でまとめて1回だけ書く。

import Foundation

public enum HealSourceWriteBack {

    public struct Outcome: Sendable {
        public var written: [HealFixInput] = []
        public var alreadyApplied: [HealFixInput] = []
        public var failures: [Failure] = []
    }

    public struct Failure: Sendable, Equatable {
        public let place: String
        public let message: String
    }

    /// ランナー機の子 run か(発行側が回収してから書き戻すので、ここでは書かない)
    static var isDispatchedChild: Bool {
        ProcessInfo.processInfo.environment[HealWriteBack.dispatchedRunEnvironmentKey] == "1"
    }

    /// 結果の記録から書き戻して、利用者向けの行を出す(英語。出し先は呼び手 = stdout か stderr)
    @discardableResult
    public static func run(records: [ScenarioRunRecord], project: TestProject,
                           emit: (String) -> Void) -> Outcome {
        run(suggestions: HealWriteBack.suggestions(from: records), project: project, emit: emit)
    }

    @discardableResult
    public static func run(suggestions: [HealWriteBack.Suggestion], project: TestProject,
                           emit: (String) -> Void) -> Outcome {
        guard !isDispatchedChild, !suggestions.isEmpty else { return Outcome() }
        if let out = ProcessInfo.processInfo.environment[HealWriteBack.collectEnvironmentKey], !out.isEmpty {
            do {
                try Collection.append(suggestions, to: URL(fileURLWithPath: out))
                return Outcome()
            } catch {
                // 渡せなかった提案を捨てない(ここで書く。子をまたぐ食い違いの検出だけが効かなくなる)
                emit("⚠️ Self-healing could not hand \(suggestions.count) selector fix(es) to the parent run"
                    + " (\(error.localizedDescription)); writing them back here")
            }
        }
        let outcome = write(suggestions, project: project)
        for line in lines(outcome, project: project) { emit(line) }
        return outcome
    }

    /// 分割した run の親が持つ受け口。子の環境へ `environment` を渡し、全部の子が終わったら `finish` を呼ぶ
    public final class Collection: @unchecked Sendable {
        // 不変条件: `url` は init で決まって変わらない。ファイルへの追記は子プロセス側(`append` の flock)
        public let url: URL

        /// 親の一時フォルダに置く(シナリオの子は自分専用の一時フォルダしか書けない = 偽の提案を混ぜられない)
        public init(directory: URL = TemporaryDirectory.url) {
            url = directory.appendingPathComponent("fleetest-heal-suggestions-\(UUID().uuidString).ndjson")
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        public var environment: (key: String, value: String) { (HealWriteBack.collectEnvironmentKey, url.path) }

        /// 子が渡した提案をまとめて書き戻す(読めない行は数えて言う。黙って捨てない)
        @discardableResult
        public func finish(project: TestProject, emit: (String) -> Void) -> Outcome {
            let (suggestions, unreadable) = Self.read(url)
            try? FileManager.default.removeItem(at: url)
            if unreadable > 0 {
                emit("⚠️ Self-healing: \(unreadable) fix suggestion line(s) handed over by the sub-runs could not be read")
            }
            return HealSourceWriteBack.run(suggestions: suggestions, project: project, emit: emit)
        }

        static func append(_ suggestions: [HealWriteBack.Suggestion], to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = Data()
            for suggestion in suggestions {
                data.append(try encoder.encode(suggestion))
                data.append(0x0A)
            }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            defer { close(fd) }
            // 並行する子の追記が行の途中で混ざらないよう、1回の書き込みを排他で囲む
            flock(fd, LOCK_EX)
            defer { flock(fd, LOCK_UN) }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }

        static func read(_ url: URL) -> (suggestions: [HealWriteBack.Suggestion], unreadable: Int) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], 0) }
            let decoder = JSONDecoder()
            var suggestions: [HealWriteBack.Suggestion] = []
            var unreadable = 0
            for line in text.split(separator: "\n") where !line.isEmpty {
                if let value = try? decoder.decode(HealWriteBack.Suggestion.self, from: Data(line.utf8)) {
                    suggestions.append(value)
                } else {
                    unreadable += 1
                }
            }
            return (suggestions, unreadable)
        }
    }

    static func write(_ suggestions: [HealWriteBack.Suggestion], project: TestProject) -> Outcome {
        let scenariosDir = project.scenariosDir.resolvingSymlinksInPath().path
        let plan = HealWriteBack.plan(
            suggestions, scenariosDir: scenariosDir,
            projectDirNames: [project.rootURL.lastPathComponent, project.name],
            // 子は親の cwd を継ぎ、記録の `file` はその cwd からの相対パス
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .resolvingSymlinksInPath().path,
            fileExists: { FileManager.default.fileExists(atPath: $0) })
        var outcome = Outcome()
        outcome.failures = plan.skipped.map { Failure(place: $0.place, message: $0.reason) }
        guard !plan.fixes.isEmpty else { return outcome }

        // 同じプロジェクトへ並行して書き戻す run(`--fleet` の子・同時に起こした2本)を直列にする。
        // 読み → 置換 → 書きの間に他者が書くと、片方の書き換えが消える
        let lock = acquireLock(project: project)
        defer { if let lock { flock(lock.fileDescriptor, LOCK_UN) } }

        for (file, fixes) in Dictionary(grouping: plan.fixes, by: \.file).sorted(by: { $0.key < $1.key }) {
            // **シンボリックリンクは書かない** —— 原子的な書き込みはリンクを普通のファイルに置き換え、
            // 実体(`scenarios/` の外にありうる)は古いまま残る
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: file)) != nil {
                outcome.failures += fixes.map { Failure(place: place(of: $0), message: "the file is a symbolic link") }
                continue
            }
            let url = URL(fileURLWithPath: file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                outcome.failures += fixes.map { Failure(place: place(of: $0), message: "cannot read the file") }
                continue
            }
            let result = HealWriteBack.apply(fixes: fixes, toSource: source)
            outcome.alreadyApplied += result.alreadyApplied
            outcome.failures += result.failures.map { failure in
                Failure(place: fixes.first { $0.id == failure.id }.map(place(of:)) ?? failure.id,
                        message: failure.message)
            }
            guard !result.written.isEmpty else { continue }
            do {
                try result.source.write(to: url, atomically: true, encoding: .utf8)
                outcome.written += result.written
            } catch {
                outcome.failures += result.written.map {
                    Failure(place: place(of: $0), message: "failed to write (\(error.localizedDescription))")
                }
            }
        }
        return outcome
    }

    static func lines(_ outcome: Outcome, project: TestProject) -> [String] {
        var lines: [String] = []
        if !outcome.written.isEmpty {
            lines.append("✏️ Self-healing wrote \(outcome.written.count) selector fix(es) back to the scenarios"
                + " — review them with git diff and commit:")
            lines += outcome.written.map {
                "   - \(display(place(of: $0), project: project)): \"\($0.oldSelector)\" → \"\($0.newSelector)\""
            }
        }
        if !outcome.failures.isEmpty {
            lines.append("⚠️ Self-healing could not write \(outcome.failures.count) selector fix(es) back"
                + " (the suggestions stay in the scenario reports):")
            lines += outcome.failures.map { "   - \(display($0.place, project: project)): \($0.message)" }
        }
        return lines
    }

    private static func place(of fix: HealFixInput) -> String { "\(fix.file):\(fix.line)" }

    /// プロジェクトのルートから見た相対パスで出す(手元のパスのときだけ)
    private static func display(_ place: String, project: TestProject) -> String {
        let root = project.rootURL.resolvingSymlinksInPath().path + "/"
        return place.hasPrefix(root) ? String(place.dropFirst(root.count)) : place
    }

    /// 取れなければ nil で進む(ロックが置けない = 状態フォルダが書けない機械でも書き戻しは止めない)。
    /// **待つ** —— 先客の書き戻しは数ファイルの読み書きで終わる
    private static func acquireLock(project: TestProject) -> FileHandle? {
        let dir = project.stateDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `FileManager.createFile` を使わない(別の inode に置き換わり、先客の flock と衝突しなくなる)
        let fd = open(dir.appendingPathComponent(HealWriteBack.lockFileName).path,
                      O_RDWR | O_CREAT | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX) == 0 else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
