// run の開始行("🚀 Starting with …")を事実に合わせて組み立てる純粋関数。
// `ProfileRunner.run` と `ApiRunCommand.run` の両実装がこれを呼ぶ ―― 別々に組み立てると、
// Android 0 台のプロファイル(iOS だけの run)でも固定文言で Android の行が出たり、iOS 0 台の
// プロファイル(Android だけの run)でも固定文言で「iOS joins…」と言ったりする事故が起きる
// (実測 2026-09-16。CLAUDE.md「2 実装の差」)。

enum RunStartLine {
    /// - Parameters:
    ///   - androidWorkers: 実際に用意できた Android ワーカー数。0 なら Android の話をしない
    ///   - eagerIOSWorkers: 開始前に建てた(late join ではない)iOS ワーカー数
    ///   - hasLateIOS: iOS がこの run の後半で合流する(late join)かどうか。呼び出し側は
    ///     `hasLateIOS` と `eagerIOSWorkers > 0` を排他的に埋める(late join なら eager は常に 0)
    static func text(androidWorkers: Int, eagerIOSWorkers: Int, hasLateIOS: Bool) -> String {
        if androidWorkers > 0 {
            let iosSuffix = hasLateIOS
                ? " (iOS joins once bridge provisioning finishes)"
                : (eagerIOSWorkers > 0 ? " + \(eagerIOSWorkers) iOS worker(s)" : "")
            return "🚀 Starting with \(androidWorkers) Android worker(s)" + iosSuffix
        }
        if eagerIOSWorkers > 0 {
            return "🚀 Starting with \(eagerIOSWorkers) iOS worker(s)"
        }
        if hasLateIOS {
            return "🚀 Starting (iOS joins once bridge provisioning finishes)"
        }
        return "🚀 Starting with 0 worker(s)"
    }
}
