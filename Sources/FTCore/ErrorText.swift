// 利用者に見せるエラー 1 行の作り方。`"\(error)"` は列挙値のダンプ
// (`bridgeConnectionRefused(context: FTCore.DriverErrorContext(engine: …), detail: …)`)になり、
// 読み手が次にやることを読み取れない(2026-09-18 の実測で 4 箇所が実際にこれを出していた)。
// **同期相手**: `ErrorTextScanTests` が ConsoleOut の行での素の `\(error)` を落とす。

import Foundation

public enum ErrorText {
    /// LocalizedError なら完成文、そうでなければ localizedDescription。
    /// **一次情報だけを足したいとき**(前置きの固定文が二重になる場合)は呼び手側で組み立てる
    public static func user(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
