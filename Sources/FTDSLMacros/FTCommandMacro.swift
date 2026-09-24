// @FTCommand("summary") の実装。展開は何も生成しない純粋なマーカー(ソース側の走査は
// Sources/FTCore/ProjectCommandIndex.swift)。ここでは付与位置と引数の形だけをコンパイル時に確かめる。

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

public struct FTCommandMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let fn = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@FTCommand can only be attached to a func declaration",
                                         id: "ftcommand-target")))
            return []
        }

        // 囲んでいる宣言は lexicalContext で見る(展開に渡る宣言は木から切り離されていることがあり、
        // parent を辿る判定は当てにならない)。先頭 = いちばん内側。extension の中とトップレベル(空)だけ許す
        if let enclosing = context.lexicalContext.first, !enclosing.is(ExtensionDeclSyntax.self) {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@FTCommand can only be attached to a top-level func or a method inside an extension",
                    id: "ftcommand-placement")))
        }

        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let first = args.first, first.label == nil,
              let literal = first.expression.as(StringLiteralExprSyntax.self),
              let summary = plainStringContent(literal), !isBlank(summary)
        else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@FTCommand needs a non-empty string literal summary: @FTCommand(\"…\")",
                    id: "ftcommand-summary")))
            return []
        }

        return []
    }

    /// 単純な(内挿を含まない)文字列リテラルの中身。内挿を含む場合は nil(拒否)
    private static func plainStringContent(_ literal: StringLiteralExprSyntax) -> String? {
        var text = ""
        for segment in literal.segments {
            guard case .stringSegment(let piece) = segment else { return nil }
            text += piece.content.text
        }
        return text
    }

    private static func isBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }
}
