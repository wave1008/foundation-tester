// TEST EXPLORER(VSCode拡張)の右クリック「削除」= 物理削除の実体。
// --method 指定: その @Test メソッドの記述だけをソースから除去する。ファイルは絶対に削除しない
//                (最後の1メソッドを消しても空クラスのまま残す)。
// --delete-file: --file を丸ごと削除する(クラスノードの削除。1クラス1ファイル前提)。
// どちらも無い場合はエラー(意図しないファイル削除を防ぐため、削除対象は明示必須)。
// 成功時は無出力で exit 0。失敗は throw(ArgumentParser が stderr に出力し非0終了。拡張が拾う)。
// 削除後のビルドは呼び出し側(拡張)が list-scenarios 再取得で行うためここでは行わない。

import ArgumentParser
import Foundation
import FTCore

struct ApiDeleteScenarioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-scenario",
        abstract: "テストクラス(.swiftファイル)またはテスト関数(@Testメソッド)を物理削除する")

    @Option(name: .customLong("file"), help: "対象の .swift 絶対パス")
    var file: String

    @Option(name: .customLong("class"), help: "対象クラス名(メソッド範囲の限定に使う)")
    var className: String

    @Option(name: .customLong("method"), help: "削除する @Test メソッド名。指定時はファイルを削除せず関数のみ除去")
    var method: String?

    @Flag(name: .customLong("delete-file"), help: "ファイルごと削除する(クラス削除)。--method とは併用しない")
    var deleteFile = false

    func run() async throws {
        guard FileManager.default.fileExists(atPath: file) else {
            throw ValidationError("ファイルが見つかりません: \(file)")
        }
        // メソッド削除は該当関数の記述だけを除去し、ファイルは絶対に残す(最後の1メソッドでも空クラスを残す)。
        // --method が来た時点でファイル削除経路には決して入らない(誤削除防止)。
        if let method {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            let updated = try ScenarioSourceEditor.removeMethod(
                inSource: source, className: className, method: method)
            try updated.write(toFile: file, atomically: true, encoding: .utf8)
            return
        }
        guard deleteFile else {
            throw ValidationError("削除対象が指定されていません(関数削除は --method、クラス削除は --delete-file)")
        }
        try FileManager.default.removeItem(atPath: file)  // クラス削除 = ファイル削除
    }
}
