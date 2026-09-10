// run の完了時に保持容量の掃除を**別プロセスの背景**で起こす。
//
// **テストの実行時間に掃除を含めない**(ユーザー決定)。run は子を起こしたら待たずに終わり、
// 掃除は `fleetest clean --background` として run の後も走り続ける。
//
// **差し込み口は結果を書く3経路**(`Fleetest.swift` のプロファイル経路 / プロファイル無し経路 /
// `ApiRunCommand`)。記録しない run(dry-run / debug)・ディスパッチの親・機械分担の親は
// そこへ来ないので起こさない(走らせた機械の子が自分の機械で起こす)。
// `RunCompletionSweepWiringTests` が本数を固定する。
//
// **子の起こし方の規律**(破ると run が終わらない・掃除が途中で殺される):
//   - **標準入出力はすべて /dev/null**。継がせると、拡張は `api run` の stdout(NDJSON)の EOF を、
//     ssh は channel の閉鎖を、**掃除が終わるまで待つ** = 掃除がテストの実行時間に乗る
//   - **`FT_PARENT_PID` を渡さない**(ParentDeathWatch を武装しない)。親の run は子より先に必ず
//     終わるので、渡すと掃除が起動直後に殺される。拡張の孤児掃除も印の無いものは殺さない。
//     自分で終わる有限の子なので孤児の心配は無い(`warm-ocr` と同じ例外)
//   - **親が決めた2つの場所を子へそのまま渡す**(`FT_PACKAGE_ROOT` / `FT_TOOL_ROOT`。どちらも既存の上書き口)。
//     子に解決し直させると、受け手の外部構成では cwd と実行ファイルの位置からツールの場所を
//     プロジェクトの場所と取り違え、受け手の録画・レポートを1度も掃除しなかった
//   - 同時起動は子の側で錠(`RetentionSweepLock`)が止める。起こす側は数えない

import FTBridgeClient
import FTCore
import Foundation

enum RunCompletionSweep {

    /// 背景の掃除の出力先(**ツール側の** `.fleetest/`。ブリッジの台帳と同じ置き場)。**毎回上書き** ——
    /// 1本の掃除の顛末だけを持つ(溜めると、それ自体が掃除の対象を増やす)
    static let logName = "cleanup.log"

    /// 結果を書き終えた直後に呼ぶ。**待たない**。`activeRunID` はこの run の runID
    /// (背景の掃除が、終わったばかりの自分の run を消さないための保護)。設定が OFF なら何もしない
    static func spawn(activeRunID: String?, log: (String) -> Void) {
        let policy = (LocalConfig.load().retention ?? RetentionPolicy()).resolved
        guard policy.effectiveSweepAfterRun, let roots = try? RetentionSweeper.Roots.resolve() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FleetRunner.selfBinaryPath())
        process.arguments = ["clean", "--background"]
            + (activeRunID.map { ["--active-run-id", $0] } ?? [])
        process.currentDirectoryURL = roots.package
        process.environment = childEnvironment(roots: roots)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("⚠️ Could not start the background cleanup: \(error.localizedDescription)")
            return
        }
        log("🧹 Cleanup continues in the background after this run"
            + " (log: \(logURL(roots: roots).path); limits: fleetest api retention)")
    }

    /// 背景の掃除の環境。**`FT_PARENT_PID` を抜き、親が決めた2つの場所を固定する**(上の規律)。
    /// 純粋関数にしてあるのはテストのため
    static func childEnvironment(roots: RetentionSweeper.Roots,
                                 base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var env = base
        env.removeValue(forKey: ParentDeathWatch.environmentKey)
        env["FT_PACKAGE_ROOT"] = roots.package.path
        env["FT_TOOL_ROOT"] = roots.tool.path
        return env
    }

    static func logURL(roots: RetentionSweeper.Roots) -> URL {
        roots.tool.appendingPathComponent(".fleetest").appendingPathComponent(logName)
    }

    /// `fleetest clean --background` の本体(子の側)。**例外を投げない・何も出さない**
    /// (出力先は /dev/null。顛末は `.fleetest/cleanup.log` にだけ残す)
    static func runInBackground(roots: RetentionSweeper.Roots, activeRunID: String?) {
        // ssh 越しの run(リモートランナー)ではセッションの終わりに SIGHUP が来うる。掃除は
        // 消し終えるまで走らせたい(冪等なので途中で死んでも壊れはしないが、毎回途中で終わると
        // 永久に片付かない)
        signal(SIGHUP, SIG_IGN)
        // 次の run がすぐ始まることがある(e2e.sh は profile を続けて回す)。**背景帯**に落として
        // CPU とディスクを譲る —— 掃除の遅れは害が無いが、次の run の遅れは害になる
        _ = setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
        // **先客がいれば黙って抜ける**(同じ機械の別の run が起こした掃除が同じものを消している)
        guard let lock = RetentionSweepLock.tryAcquire() else { return }
        defer { withExtendedLifetime(lock) {} }

        let logURL = Self.logURL(roots: roots)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        defer { try? handle?.close() }
        let stamp = ISO8601DateFormatter()
        func write(_ line: String) {
            handle?.write(Data("\(stamp.string(from: Date())) \(line)\n".utf8))
        }

        write("started (pid \(getpid())\(activeRunID.map { ", after run \($0)" } ?? ""))"
            + " — projects: \(roots.package.path), tool: \(roots.tool.path)")
        let report = RetentionSweeper.clean(
            roots: roots, categories: RetentionSweeper.Category.allCases,
            policy: (LocalConfig.load().retention ?? RetentionPolicy()).resolved,
            dryRun: false, activeRunID: activeRunID,
            log: write, notice: write)
        for category in report.categories {
            write("\(category.category): freed \(RetentionSweeper.bytesText(category.freedBytes))"
                + " from \(category.deletedSessions)/\(category.plannedSessions) session(s),"
                + " \(RetentionSweeper.bytesText(category.keptBytes)) kept"
                + " (limit \(RetentionSweeper.bytesText(category.maxBytes)); sweeps above"
                + " \(RetentionSweeper.bytesText(category.sweepLineBytes)))")
        }
        write("finished: freed \(RetentionSweeper.bytesText(report.freedBytes))")
    }
}
