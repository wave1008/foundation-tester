// `fleetest run`(RunScenarios)と `fleetest api run`(ApiRunCommand)は**同じ run を2つの入口で
// 提供する2実装**。共通のオプション宣言と検査は RunCommonOptions に1つだが、それ以外のフラグと
// 配線(受け取った値を実行段へ渡す)は別々に持っている。片方だけに足した変更は
// **どちらの経路も緑のまま**通るので(実行されるのは足したほうだけ)、run.json にも E2E にも出ない。
// 実際にこの分岐から出た欠陥: `--runner local` の絞り込みが api run 側だけ通っていなかった /
// run フックの呼び出しが2箇所にあり片方が漏れた / `exactScenarioCount` の台数削減が api run にだけ無かった。
//
// ここで**意図した差分だけ**を等号で固定する。片側にフラグを足すと落ちるので、
// 「RunCommonOptions に足す」か「片側だけでよい理由をここへ書く」かを必ず選ぶことになる。
// 両方にあるフラグは、RunCommonOptions から来るか理由付きで別々に宣言するかを固定する
// (testFlagsOnBothSidesComeFromTheSharedOptions。両方へ別々に足すと上の固定は素通しする)。
//
// 判定は**ヘルプの宣言列**から採る。実際に利用者へ見えている面がそのまま対象になり、
// @OptionGroup で畳まれた DriverOptions も含まれる(ソース走査だと拾えない)。

import XCTest
import ArgumentParser
@testable import fleetest

final class RunCommandFlagParityTests: XCTestCase {

    // MARK: - 意図した差分(ここが唯一の定義元)

    /// `fleetest run` にだけあるもの。**理由が書けないものはここへ足さない** ――
    /// 書けないなら RunCommonOptions へ移すのが正しい。
    private static let runOnly: [String: String] = [
        "--broadcast": "分配の差し替え(ScenarioDispatch.broadcast)は ProfileRunner にしか無い。拡張にブロードキャストの導線が無いため api run へは配線していない",
        "--failed": "前回失敗ぶんの再実行。拡張は Test Explorer 側が対象を持っているので、解決済みの --scenario を渡す",
        "--fleet": "profiles/fleets/<name>.json による多ホスト並列。拡張は api run --runner を機械ごとに立てる別の経路(RemoteMonitorFanout)を持つ",
        "--folder": "scenarios/ 直下のフォルダ実行。拡張は folder の TestItem を配下 leaf へ展開してから渡す(runHandler.ts)ので、フォルダ名のまま送る口が要らない",
        "--force-lock": "他人の dispatch.lock を奪う運用オプション(実行プロファイル / --runner / --fleet のどれかが前提)。GUI から他人の run を殺す導線を作らない",
        "--junit": "CI 向けの JUnit XML 出力。拡張は NDJSON をそのまま読む",
        "--quiet": "ステップ行を止めてサマリだけ出す。api run は常に NDJSON なので概念が無い",
        "--split": "--fleet の分配方式。--fleet が CLI 専用なので従属",
    ]

    /// `fleetest api run` にだけあるもの。
    private static let apiOnly: [String: String] = [
        "--breakpoint": "DAP(拡張のデバッガ)専用。CLI にステップ実行の受け皿が無い",
        "--debug": "同上(debugAdapter.ts が付ける)",
        "--pause-on-start": "同上",
        "--default-timeout": "run には専用フラグが無く `--set defaultTimeout=` が口(既知の非対称。埋めるなら run へ足す)",
        "--scenario-timeout": "同上",
    ]

    /// 両方にあるが `RunCommonOptions` に入れず、各コマンドが別々に宣言しているもの。
    /// **意味かヘルプの内容が2本で違う**ものだけを置く —— 同じなら共有の宣言へ移すのが正しい。
    private static let declaredSeparately: [String: String] = [
        "--scenario": "run は省略で全部・api run は1本以上必須(拡張が解決済みの対象を渡す)",
        "--port": "run は繰り返して並列・api run は1回だけ(--profile 無しの並列経路を持たない)",
        "--set": "ヘルプが衝突する専用フラグを名指しする(api run だけ --default-timeout/--scenario-timeout を持つ)",
        "--report-dir": "api run のヘルプは --profile のときプロファイルの reportDir を上書きすることを書く",
        "--dry-run": "ヘルプが別(run は No-Load-Run の検出内容・api run は --profile のワーカー構築の省略)",
        "--runner": "api run はリモートの NDJSON を中継する(ヘルプが違う)",
        "--wait-lock": "run だけ --force-lock との併用不可を持つ",
        "--performance": "run は --fleet でもよい(前提とヘルプが違う)",
    ]

    // MARK: - 検証

    func testRunAndApiRunDivergeOnlyWhereDocumented() {
        let run = Self.longFlags(of: RunScenarios.self)
        let api = Self.longFlags(of: ApiRunCommand.self)

        // 抽出そのものが壊れた場合に**空集合どうしの一致で素通し**しないよう、先に規模を見る。
        // 数字は「両方が20個以上のフラグを持つ」ことだけを言う下限で、増減で調整しない。
        XCTAssertGreaterThan(run.count, 20, "run のフラグ抽出に失敗している(ヘルプの書式が変わった?)")
        XCTAssertGreaterThan(api.count, 20, "api run のフラグ抽出に失敗している(ヘルプの書式が変わった?)")

        assertEqual(actual: run.subtracting(api), pinned: Self.runOnly,
                    side: "fleetest run", other: "fleetest api run", literal: "runOnly")
        assertEqual(actual: api.subtracting(run), pinned: Self.apiOnly,
                    side: "fleetest api run", other: "fleetest run", literal: "apiOnly")
    }

    /// 両方にあるフラグは `RunCommonOptions`(共有の宣言)から来ているか、`declaredSeparately` に理由付きで
    /// 載っているかのどちらか。**両方へ別々に宣言して足す**と、上の差分のテストは素通しする(集合が割れない)ので、
    /// ここで共有の宣言へ寄せさせる。
    func testFlagsOnBothSidesComeFromTheSharedOptions() {
        let both = Self.longFlags(of: RunScenarios.self).intersection(Self.longFlags(of: ApiRunCommand.self))
        let shared = Self.longFlags(of: RunCommonOptions.self)
        XCTAssertGreaterThan(shared.count, 5, "RunCommonOptions のフラグ抽出に失敗している")
        let separately = both.subtracting(shared)
        XCTAssertEqual(separately.sorted(), Self.declaredSeparately.keys.sorted(),
                       "両方にあるのに RunCommonOptions に無いフラグが declaredSeparately と食い違っています。"
                       + "同じ意味なら RunCommonOptions へ移し、2本で意味が違うなら理由を declaredSeparately に書いてください")
        XCTAssertEqual(Self.flagsMissingAReason(in: Self.declaredSeparately), [])
    }

    /// 差分の表に**理由の無い行**を置かせない。理由が書けないなら、その差分は意図ではなく漏れ。
    func testEveryDocumentedDivergenceCarriesAReason() {
        XCTAssertEqual(Self.flagsMissingAReason(in: Self.runOnly), [])
        XCTAssertEqual(Self.flagsMissingAReason(in: Self.apiOnly), [])
    }

    /// 上の検査の**陽性対照**。現に空欄が1つも無いので、上のテストだけでは
    /// 「常に空配列を返す実装」と区別できない(見逃しに気付けない)。
    func testMissingReasonIsActuallyDetected() {
        XCTAssertEqual(Self.flagsMissingAReason(in: ["--a": "理由", "--b": "", "--c": "   "]),
                       ["--b", "--c"])
    }

    /// 宣言列パーサの砦。**説明文に出てくるフラグを拾わない**ことを、実コマンドとは無関係に固定する。
    /// ここが緩むと、片側の説明文が別のフラグに言及しただけで差分表が動く。
    func testHelpParserReadsOnlyTheDeclarationColumn() {
        // 実際のヘルプに出る形をそのまま使う: 宣言が長く、説明列との区切りが**1スペースしかない**行。
        let help = """
        OPTIONS:
          --project <project>     Test project name
          --wait-lock <wait-lock> Poll until the lock is released. Needs --profile, --runner or --fleet. Cannot be combined with --force-lock
          --lpt-history-runs <lpt-history-runs>
                                  Number of past runs to read. See --no-lpt
          -h, --help              Show help information.
        """
        XCTAssertEqual(Self.longFlags(fromHelp: help),
                       ["--project", "--wait-lock", "--lpt-history-runs"],
                       "説明列の --profile/--runner/--fleet/--force-lock/--no-lpt を宣言と取り違えている")
    }

    /// 宣言列でないところに出るフラグは全部無視する: USAGE 節の折り返し(`[--flag …]`)と、
    /// **字下げの無い散文**(abstract が `--profile is required.` のように始まる形)。
    func testHelpParserIgnoresUsageAndUnindentedProse() {
        let help = """
        OVERVIEW: Run scenarios.
        --profile is required when dispatching remotely.

        USAGE: fleetest run <options>
                            [--project <project>] [--broadcast]

        OPTIONS:
          --quiet                 Suppress step lines
        """
        XCTAssertEqual(Self.longFlags(fromHelp: help), ["--quiet"],
                       "字下げの無い散文か USAGE の折り返しを宣言として読んでいる")
    }

    // MARK: - 補助

    /// 理由が空(空白だけを含む)のフラグ。名前順。
    static func flagsMissingAReason(in table: [String: String]) -> [String] {
        table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .keys.sorted()
    }

    private func assertEqual(actual: Set<String>, pinned: [String: String],
                             side: String, other: String, literal: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = Set(pinned.keys)
        guard actual != expected else { return }

        let added = actual.subtracting(expected).sorted()
        let removed = expected.subtracting(actual).sorted()
        var message = "\(side) にしか無いフラグの集合が \(literal) と食い違っています。\n"
        if !added.isEmpty {
            message += """

            ● \(side) にだけ増えた: \(added.joined(separator: " "))
              → 両方に要るなら RunCommonOptions へ移すか、片側だけでよい理由を \(literal) に書いてください。

            """
        }
        if !removed.isEmpty {
            message += """

            ● \(side) から消えた(= 両方が持つようになったか、削除された): \(removed.joined(separator: " "))
              → \(literal) から外してください。

            """
        }
        message += "貼り付け用:\n" + Self.literalSource(actual, pinned: pinned, name: literal)
        XCTFail(message, file: file, line: line)
    }

    /// 失敗メッセージが**そのまま貼れる Swift リテラル**を出す(BridgeContractTests と同じ運用)。
    /// 既に理由が書いてある行はその理由を残し、新しい行だけ穴を空けて出す。
    private static func literalSource(_ flags: Set<String>, pinned: [String: String], name: String) -> String {
        let body = flags.sorted().map { flag in
            "        \"\(flag)\": \"\(pinned[flag] ?? "TODO: 片側だけでよい理由を書く")\","
        }.joined(separator: "\n")
        return "    private static let \(name): [String: String] = [\n\(body)\n    ]"
    }

    /// ヘルプの**宣言列**から `--long` を集める。
    ///
    /// **空白の数で宣言列と説明列を分けない** —— 宣言が説明列に届く長さだと区切りが1スペースになり
    /// (`--wait-lock <wait-lock> Instead of …`)、説明文に出てくる `--runner` や `--fleet.` まで
    /// フラグとして拾う。代わりに**宣言列の文法**で切る: 行頭から「フラグ」か「`<値>`」である
    /// 限り読み進め、それ以外の語(= 説明文の1語目)で止める。
    private static func longFlags<C: ParsableArguments>(of command: C.Type) -> Set<String> {
        longFlags(fromHelp: command.helpMessage(columns: 10_000))
    }

    /// 文字列を受ける形で切り出してある —— 実コマンドのヘルプ経由でしか叩けないと、
    /// 「説明列を読んでしまう」退行が**現に共通フラグしか説明文に出ていない**という理由で
    /// 素通しする(変異で確認済み)。合成ヘルプで直接叩けるようにして境界へ寄せている。
    static func longFlags(fromHelp help: String) -> Set<String> {
        var found: Set<String> = []
        for line in help.split(separator: "\n", omittingEmptySubsequences: false) {
            // 宣言行は必ず字下げされている。字下げの無い行(OVERVIEW / USAGE の1行目・
            // 節見出し・abstract の散文)は、`--profile is required.` のように
            // フラグで始まっていても宣言ではない
            guard line.hasPrefix("  ") else { continue }
            for token in line.drop(while: { $0 == " " }).split(separator: " ") {
                let word = token.hasSuffix(",") ? String(token.dropLast()) : String(token)
                // 宣言列は「フラグ」だけでできている。`<値>` でも説明文の1語目でも、
                // フラグでない語が来た時点で宣言は終わり(USAGE の折り返し `[--flag …]` も
                // `[` 始まりなのでここで止まる)
                guard Self.isFlag(word) else { break }
                guard word.hasPrefix("--"), word != "--help", word != "--version" else { continue }
                found.insert(word)
            }
        }
        return found
    }

    /// `--long-flag` / `-h`。
    ///
    /// **効いているのは「フラグの形かどうか」だけ**で、説明文に届かせないのは呼び出し側の
    /// `break`(最初の非フラグで宣言列が終わる)。文字種の厳しさ(`--fleet.` を弾く)は
    /// 保険で、いまのヘルプ書式では**説明文の1語目がフラグの形になる行が無いため発火しない**
    /// —— 変異テストで確認済み。緩めると保険が消えるだけなので残すが、これを守るテストは無い。
    private static func isFlag(_ word: String) -> Bool {
        if word.hasPrefix("--") {
            let name = word.dropFirst(2)
            return !name.isEmpty && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
        }
        guard word.hasPrefix("-"), word.count == 2, let short = word.last else { return false }
        return short.isLetter
    }
}
