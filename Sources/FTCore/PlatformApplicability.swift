// 「このシナリオはこの run の対象か」を1箇所で決める。
// 対象外(`@TestClass(platform:)` / `@Test(platform:)` が run に無い OS を指している)は
// **実行キューに入れる前に外す** —— 入れると RunOrchestrator の「担当ワーカーなし」に落ち、
// 意図された対象外が**失敗として数えられる**(2026-08-19 まで実際にそうなっていた)。

import Foundation

public enum PlatformApplicability {
    public struct Partition<Item> {
        public let runnable: [Item]
        public let notApplicable: [Item]

        public init(runnable: [Item], notApplicable: [Item]) {
            self.runnable = runnable
            self.notApplicable = notApplicable
        }
    }

    /// platform を宣言していないシナリオ(nil)は常に runnable —— 既定 platform で走るのが仕様で、
    /// ここで落とすと従来動いていた両OS対応シナリオが消える。
    /// runPlatforms が空のときも全件 runnable —— 「どの OS で回すか分からない」を「全部対象外」に
    /// 倒すと、デバイス解決に失敗しただけの run が**1本も走らないまま緑**になる。
    public static func partition<Item>(_ items: [Item], runPlatforms: Set<String>,
                                       platform: (Item) -> String?) -> Partition<Item> {
        guard !runPlatforms.isEmpty else {
            return Partition(runnable: items, notApplicable: [])
        }
        var runnable: [Item] = []
        var notApplicable: [Item] = []
        for item in items {
            if let declared = platform(item), !runPlatforms.contains(declared) {
                notApplicable.append(item)
            } else {
                runnable.append(item)
            }
        }
        return Partition(runnable: runnable, notApplicable: notApplicable)
    }

    /// 記録・表示に使う理由(1シナリオ分)。宣言した OS 名と、この run が回す OS を両方出す ——
    /// 片方だけだと「なぜ外れたか」がレポートから読めない
    public static func reason(declared: String, runPlatforms: Set<String>) -> String {
        let available = runPlatforms.sorted().joined(separator: ", ")
        return "not applicable: declared platform \(declared),"
            + " but this run covers \(available.isEmpty ? "no platform" : available)"
    }
}
