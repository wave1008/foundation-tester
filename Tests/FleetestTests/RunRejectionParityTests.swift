// `fleetest run`(RunScenarios)と `fleetest api run`(ApiRunCommand)は同じ run の2つの入口を
// **手写しで持つ2実装**。RunCommandFlagParityTests は**フラグ名の集合**しか見ないので、
// 「同じフラグが両方にあるのに、併用不可・必須の検査が片方にしか無い」型の分岐を**1つも
// 捕まえられない** —— 現に `--profile` + `--port` は run で黙って無視され api run では
// エラーになっていた(同じ打鍵が片方で通り片方で落ちる)。
//
// ここは**規則そのもの**を同じ打鍵で両方へ当て、受理/拒否の一致を等号で固定する。
// 片方だけに規則を足すと落ちるので、「両方に足す」か「片側だけでよい理由を divergent へ書く」
// かを必ず選ぶことになる。

import XCTest
import ArgumentParser
@testable import fleetest

final class RunRejectionParityTests: XCTestCase {

    /// 両コマンドへ**同じ意味で**渡せる打鍵。`api run` は `--scenario` が必須なのでそこだけ補う
    private struct Combination {
        let label: String
        let arguments: [String]
        /// 期待する結果。両コマンドがこの通りに揃っていることを見る
        let rejected: Bool
    }

    private static let combinations: [Combination] = [
        // 黙殺していた4件(この表の存在理由)
        .init(label: "profile + port", arguments: ["--profile", "p", "--port", "8200"], rejected: true),
        .init(label: "profile + platform", arguments: ["--profile", "p", "--platform", "android"], rejected: true),
        .init(label: "profile + serial", arguments: ["--profile", "p", "--serial", "R58M"], rejected: true),
        .init(label: "profile + app-id", arguments: ["--profile", "p", "--app-id", "com.example"], rejected: true),
        .init(label: "performance without profile", arguments: ["--performance"], rejected: true),

        // ディスパッチ先
        .init(label: "runner without profile", arguments: ["--runner", "m1"], rejected: true),
        .init(label: "runner local without profile", arguments: ["--runner", "local"], rejected: false),
        .init(label: "runner with profile", arguments: ["--profile", "p", "--runner", "m1"], rejected: false),

        // --set(実行プロファイルの上書き)
        .init(label: "set profile-only key without profile",
              arguments: ["--set", "iosInappEngine=false"], rejected: true),
        .init(label: "set profile-only key with profile",
              arguments: ["--profile", "p", "--set", "iosInappEngine=false"], rejected: false),
        .init(label: "set record without profile", arguments: ["--set", "record=true"], rejected: true),
        .init(label: "set unknown key", arguments: ["--set", "nosuchkey=1"], rejected: true),
        .init(label: "set without '='", arguments: ["--set", "noequals"], rejected: true),
        .init(label: "set reportDir collides with --report-dir",
              arguments: ["--report-dir", "/tmp/a", "--set", "reportDir=/tmp/b"], rejected: true),

        // --platform の値そのものの検証
        .init(label: "invalid platform value", arguments: ["--platform", "iOS"], rejected: true),
        .init(label: "valid platform alone", arguments: ["--platform", "android"], rejected: false),

        // --dry-run はデバイスにも録画にも触れないので、profile-only なキーの `--set` を
        // 理由に拒否しない(run はもとから通していた。api run 側の検査に `--dry-run` の除外が
        // 無かったのが割れの原因。)
        .init(label: "dry-run set profile-only key without profile",
              arguments: ["--dry-run", "--set", "iosInappEngine=false"], rejected: false),
        .init(label: "dry-run set record without profile",
              arguments: ["--dry-run", "--set", "record=true"], rejected: false),

        // 陰性対照。これが無いと「常に throw する実装」と区別できない
        .init(label: "profile alone", arguments: ["--profile", "p"], rejected: false),
        .init(label: "port alone", arguments: ["--port", "8200"], rejected: false),
        .init(label: "app-id alone", arguments: ["--app-id", "com.example"], rejected: false),
        .init(label: "performance with profile", arguments: ["--profile", "p", "--performance"], rejected: false),
        .init(label: "no arguments", arguments: [], rejected: false),
    ]

    /// 意図的に片側だけが拒否する打鍵。**理由が書けないものはここへ足さない** ——
    /// 書けないなら、それは意図ではなく片側だけに入れた検査の漏れ
    private static let divergent: [String: String] = [
        "port given twice": "api run の --profile 無し経路(runDirect)は単一接続を逐次に流すだけで、"
            + "fleetest run の runParallel に相当する多重ポート経路を持たない。黙って1本目だけ使わずに拒否する",
    ]

    private static let divergentCombinations: [Combination] = [
        .init(label: "port given twice", arguments: ["--port", "8123", "--port", "8124"], rejected: true),
    ]

    /// 両方が拒否するが**逃げ道の案内だけ**が違う打鍵。規則は同じで、片方にしか無い
    /// オプションを案内しているだけなので揃えようがない。**規則そのものが違うものはここへ入れない**
    private static let divergentMessages: [String: String] = [
        "performance without profile": "api run に --fleet が無い(run は --profile または --fleet で、api run は --profile だけ)",
        "set record without profile": "api run の --profile 無し経路には多重ポートの並列が無いので、"
            + "run が案内する「--port を2回以上」という逃げ道が存在しない",
    ]

    // MARK: - 検証

    func testBothCommandsAgreeOnEveryCombination() {
        for combination in Self.combinations {
            let run = Self.rejects(RunScenarios.self, arguments: combination.arguments)
            let api = Self.rejects(ApiRunCommand.self,
                                   arguments: ["--scenario", "Klass.method"] + combination.arguments)
            XCTAssertEqual(run.rejected, combination.rejected,
                           "fleetest run [\(combination.label)]: "
                           + (combination.rejected ? "拒否されるはずが通った" : "通るはずが拒否された: \(run.message)"))
            XCTAssertEqual(api.rejected, combination.rejected,
                           "fleetest api run [\(combination.label)]: "
                           + (combination.rejected ? "拒否されるはずが通った" : "通るはずが拒否された: \(api.message)"))
            guard run.rejected == api.rejected else {
                XCTFail("""
                    [\(combination.label)] で run と api run の判定が割れています \
                    (run: \(run.rejected ? "拒否" : "受理") / api run: \(api.rejected ? "拒否" : "受理"))。
                      → 同じ検査を両方に置くか、片側だけでよい理由を divergent へ書いてください。
                      run: \(run.message)
                      api run: \(api.message)
                    """)
                continue
            }
        }
    }

    /// 両方が拒否する打鍵は、**逃げ道の案内が違うものを除いて**文言も揃っていること。
    /// 判定が同じでも説明が違えば、利用者は同じ打鍵に別の理由を告げられる(規則が2つ育っている印)。
    /// 違ってよいのは「片方にしか無いオプションを逃げ道として案内している」場合だけ
    func testRejectionMessagesMatchExceptWhereTheEscapeHatchDiffers() {
        var differing: Set<String> = []
        for combination in Self.combinations where combination.rejected {
            let run = Self.rejects(RunScenarios.self, arguments: combination.arguments)
            let api = Self.rejects(ApiRunCommand.self,
                                   arguments: ["--scenario", "Klass.method"] + combination.arguments)
            guard run.rejected, api.rejected else { continue }
            // 完全一致は求めない —— 片側だけが「この経路には並列が無い」等の事情を括弧書きで足す。
            // 規則そのもの(先頭の1文)で比べる
            let runRule = Self.firstSentence(run.message)
            let apiRule = Self.firstSentence(api.message)
            guard runRule != apiRule else { continue }
            differing.insert(combination.label)
            XCTAssertNotNil(Self.divergentMessages[combination.label], """
                [\(combination.label)] 拒否の理由が食い違っています。
                  → 同じ文言にするか、片側だけ違ってよい理由を divergentMessages へ書いてください。
                  run: \(runRule)
                  api run: \(apiRule)
                """)
        }
        XCTAssertEqual(differing, Set(Self.divergentMessages.keys),
                       "divergentMessages の表と、実際に文言が割れている打鍵が食い違っています")
    }

    /// 片側だけが拒否する打鍵は、divergent に理由付きで載っているものだけ
    func testDivergentCombinationsAreDocumented() {
        for combination in Self.divergentCombinations {
            let run = Self.rejects(RunScenarios.self, arguments: combination.arguments)
            let api = Self.rejects(ApiRunCommand.self,
                                   arguments: ["--scenario", "Klass.method"] + combination.arguments)
            XCTAssertNotEqual(run.rejected, api.rejected,
                              "[\(combination.label)] はもう割れていません。divergent から外してください")
            let reason = Self.divergent[combination.label] ?? ""
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           "[\(combination.label)] に理由がありません")
        }
        XCTAssertEqual(Set(Self.divergent.keys), Set(Self.divergentCombinations.map(\.label)),
                       "divergent の表と打鍵の一覧が食い違っています")
    }

    /// 上の検査の**陽性対照**。現に理由の空欄が1つも無いので、これが無いと
    /// 「常に空でないと言う実装」と区別できない
    func testEmptyReasonWouldBeDetected() {
        let table = ["--a": "理由あり", "--b": "   "]
        let empty = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys.sorted()
        XCTAssertEqual(empty, ["--b"])
    }

    // MARK: - 補助

    private static func rejects<C: ParsableCommand>(
        _ command: C.Type, arguments: [String]
    ) -> (rejected: Bool, message: String) {
        do {
            _ = try command.parse(arguments)
            return (false, "")
        } catch {
            return (true, command.message(for: error))
        }
    }

    /// 「規則そのもの」= 最初の括弧・改行の手前まで
    private static func firstSentence(_ message: String) -> String {
        let head = message.split(separator: "\n").first.map(String.init) ?? message
        guard let paren = head.firstIndex(of: "(") else {
            return head.trimmingCharacters(in: .whitespaces)
        }
        return String(head[head.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
    }
}
