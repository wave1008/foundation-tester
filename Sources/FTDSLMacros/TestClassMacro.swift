// @TestClass(app:platform:) の実装。
// - extension ロール: FTTestClassDefinition conformance と ftDescriptor(@Test メソッドの一覧)を生成
// - peer ロール: objc ランタイム発見用の登録クラス __FTReg_<クラス名> を生成
// マクロは糖衣であり、生成物は FTDSL の普通のプロトコル conformance +クラス。手書きでも同じものが書ける。

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct FTDSLDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String, id: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.diagnosticID = MessageID(domain: "FTDSLMacros", id: id)
        self.severity = severity
    }
}

public struct TestClassMacro {

    /// @Test が付いたメソッドの情報
    struct ScenarioMethod {
        let name: String
        /// @Test の第1引数(文字列リテラル式をそのまま転写)。省略時は nil
        let titleExpr: String?
        /// @Test(platform:) の引数式(verbatim 転写)。省略時は nil = クラス側に従う
        let platformExpr: String?
        /// メソッドに @Deleted が付いている(クラス側の @Deleted は展開時に OR する)
        let deleted: Bool
    }

    /// 属性リストに @Deleted(FTDSL.Deleted も可)が含まれるか
    static func hasDeleted(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { attr in
            guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
            let name = attrSyntax.attributeName.trimmedDescription
            return name == "Deleted" || name.hasSuffix(".Deleted")
        }
    }

    /// 同一クラス内に「引数なし・非async・非throws」の指定名メソッドがあるか
    /// (setUp / tearDown のライフサイクル検出。基底クラスからの継承は見ない = 同じクラスに書く)
    static func hasLifecycleMethod(_ name: String, in declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            guard let fn = member.decl.as(FunctionDeclSyntax.self), fn.name.text == name else {
                return false
            }
            return fn.signature.parameterClause.parameters.isEmpty
                && fn.signature.effectSpecifiers == nil
        }
    }

    /// 型宣言のメンバーから @Test メソッドを収集する
    static func scenarioMethods(in declaration: some DeclGroupSyntax,
                                context: some MacroExpansionContext) -> [ScenarioMethod] {
        var result: [ScenarioMethod] = []
        for member in declaration.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else { continue }
            var titleExpr: String?
            var platformExpr: String?
            var isScenario = false
            for attr in fn.attributes {
                guard let attrSyntax = attr.as(AttributeSyntax.self) else { continue }
                let name = attrSyntax.attributeName.trimmedDescription
                guard name == "Test" || name.hasSuffix(".Test") else { continue }
                isScenario = true
                guard let args = attrSyntax.arguments?.as(LabeledExprListSyntax.self) else { continue }
                for arg in args {
                    // title はラベル無しの第1引数、platform はラベル付き
                    switch arg.label?.text {
                    case nil: titleExpr = arg.expression.trimmedDescription
                    case "platform": platformExpr = arg.expression.trimmedDescription
                    default: break
                    }
                }
            }
            guard isScenario else { continue }

            // シナリオメソッドは「引数なし・非async・非throws」のみサポート
            let sig = fn.signature
            let hasParams = !sig.parameterClause.parameters.isEmpty
            let hasEffects = sig.effectSpecifiers != nil
            if hasParams || hasEffects {
                context.diagnose(Diagnostic(
                    node: Syntax(fn.name),
                    message: FTDSLDiagnostic(
                        "@Test methods must take no arguments and be neither async nor throws: func \(fn.name.text)()",
                        id: "scenario-signature")))
                continue
            }
            result.append(ScenarioMethod(name: fn.name.text, titleExpr: titleExpr,
                                         platformExpr: platformExpr,
                                         deleted: hasDeleted(fn.attributes)))
        }
        return result
    }

    /// @TestClass(app: "...", platform: "...") の引数式を取り出す(式は verbatim 転写)。
    /// 省略時は "nil" ―― 空文字にすると「アプリ未指定」と「空文字を指定した」が descriptor で
    /// 区別できなくなり、実行プロファイルからの解決へ落ちない
    static func arguments(of node: AttributeSyntax) -> (app: String, platform: String) {
        var app = "nil"
        var platform = "nil"
        if let args = node.arguments?.as(LabeledExprListSyntax.self) {
            for arg in args {
                switch arg.label?.text {
                case "app": app = arg.expression.trimmedDescription
                case "platform": platform = arg.expression.trimmedDescription
                default: break
                }
            }
        }
        return (app, platform)
    }

    static func requireClass(_ declaration: some DeclGroupSyntax,
                             node: AttributeSyntax,
                             context: some MacroExpansionContext) -> ClassDeclSyntax? {
        guard let cls = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@TestClass can only be attached to a class", id: "not-a-class")))
            return nil
        }
        return cls
    }
}

// MARK: - extension ロール(conformance + ftDescriptor)

extension TestClassMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let cls = requireClass(declaration, node: node, context: context) else { return [] }
        // 既に手書きで conformance 済みならマクロは何も足さない
        guard !protocols.isEmpty else { return [] }

        let className = cls.name.text
        let (app, platform) = arguments(of: node)
        let methods = scenarioMethods(in: declaration, context: context)
        // クラスに @Deleted が付いていれば全シナリオが削除済み扱い
        let classDeleted = hasDeleted(cls.attributes)

        // setUp/tearDown があれば run クロージャに織り込む。ftRunSetUp/ftRunTearDown で包むのは
        // 記録のセクション分けと、失敗時の扱い(setUp 失敗=シナリオ中断 / tearDown=失敗後も実行)のため
        let hasSetUp = hasLifecycleMethod("setUp", in: declaration)
        let hasTearDown = hasLifecycleMethod("tearDown", in: declaration)
        let entries = methods.map { m in
            let deletedArg = (classDeleted || m.deleted) ? "\n                deleted: true," : ""
            // ライフサイクル無しのときは従来どおり 1 式のまま(生成コードを増やさない)
            var body = "\(className)().\(m.name)()"
            if hasSetUp || hasTearDown {
                body = "let ftInstance = \(className)(); "
                if hasSetUp { body += "FTDSL.ftRunSetUp { ftInstance.setUp() }; " }
                body += "ftInstance.\(m.name)()"
                if hasTearDown { body += "; FTDSL.ftRunTearDown { ftInstance.tearDown() }" }
            }
            let platformArg = m.platformExpr.map { "\n                platform: \($0)," } ?? ""
            return """
                        FTDSL.FTScenarioDescriptor(
                            name: \(literalString(m.name)),
                            title: \(m.titleExpr ?? "\"\""),\(deletedArg)\(platformArg)
                            run: { \(body) }),
            """
        }.joined(separator: "\n")

        let ext = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: \(raw: literalString(className)),
                        app: \(raw: app),
                        platform: \(raw: platform),
                        scenarios: [
            \(raw: entries)
                        ])
                }
            }
            """)
        return [ext]
    }

    /// Swift 文字列リテラルとしてエスケープする(日本語はそのまま)
    static func literalString(_ text: String) -> String {
        var escaped = ""
        for ch in text {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.append(ch)
            }
        }
        return "\"\(escaped)\""
    }
}

// MARK: - peer ロール(objc ランタイム発見用の登録クラス)

extension TestClassMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let cls = declaration.as(ClassDeclSyntax.self) else { return [] }
        let className = cls.name.text
        let reg: DeclSyntax =
            """
            final class __FTReg_\(raw: className): FTDSL.FTScenarioRegistration {
                override class var descriptor: FTDSL.FTTestClassDescriptor { \(raw: className).ftDescriptor }
            }
            """
        return [reg]
    }
}

// MARK: - @Test(マーカー。@TestClass 側が読むだけで何も生成しない)

public struct TestMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(FunctionDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic("@Test can only be attached to a method", id: "not-a-function")))
            return []
        }
        return []
    }
}

// MARK: - @Deleted(論理削除マーカー。@TestClass 側が読むだけで何も生成しない)

public struct DeletedMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) || declaration.is(FunctionDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@Deleted can only be attached to a test class or a @Test method",
                    id: "deleted-target")))
            return []
        }
        return []
    }
}
