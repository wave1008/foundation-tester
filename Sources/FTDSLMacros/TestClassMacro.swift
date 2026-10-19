// @TestClass(platform:) の実装。
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
        /// @Test(scenarioTimeout:) の引数式(verbatim 転写)。省略時は nil。整数リテラルの 0 以下は展開前に弾く
        let scenarioTimeoutExpr: String?
        /// メソッドに @Deleted が付いている(クラス側の @Deleted は展開時に OR する)
        let deleted: Bool
        /// メソッドに @Draft が付いている(クラス側の @Draft は展開時に OR する)
        let draft: Bool
    }

    /// 属性リストに @Deleted(FTDSL.Deleted も可)が含まれるか
    static func hasDeleted(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { attr in
            guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
            let name = attrSyntax.attributeName.trimmedDescription
            return name == "Deleted" || name.hasSuffix(".Deleted")
        }
    }

    /// 属性リストに @Draft(FTDSL.Draft も可)が含まれるか
    static func hasDraft(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { attr in
            guard let attrSyntax = attr.as(AttributeSyntax.self) else { return false }
            let name = attrSyntax.attributeName.trimmedDescription
            return name == "Draft" || name.hasSuffix(".Draft")
        }
    }

    /// 同一クラス内に「引数なし・非async・非throws」の指定名メソッドがあるか
    /// (beforeAll / afterAll / beforeEach / afterEach / setUpDevice / tearDownDevice のライフサイクル検出。基底クラスからの継承は見ない = 同じクラスに書く)
    static func hasLifecycleMethod(_ name: String, in declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            guard let fn = member.decl.as(FunctionDeclSyntax.self), fn.name.text == name else {
                return false
            }
            return fn.signature.parameterClause.parameters.isEmpty
                && fn.signature.effectSpecifiers == nil
        }
    }

    /// 改名前のライフサイクル名(`setUp` / `tearDown`)。**普通のメソッドとして黙って呼ばれなくなる**
    /// (コンパイルエラーにならない)ので、ここで名指しする
    static let renamedLifecycle: [String: String] = ["setUp": "beforeEach", "tearDown": "afterEach"]

    static func diagnoseRenamedLifecycle(in declaration: some DeclGroupSyntax,
                                         context: some MacroExpansionContext) {
        for member in declaration.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self),
                  let renamed = renamedLifecycle[fn.name.text],
                  fn.signature.parameterClause.parameters.isEmpty else { continue }
            context.diagnose(Diagnostic(
                node: Syntax(fn.name),
                message: FTDSLDiagnostic(
                    "\(fn.name.text)() is never called: the per-test hook is \(renamed)()"
                        + " — rename it to func \(renamed)()",
                    id: "renamed-lifecycle", severity: .warning)))
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
            var scenarioTimeoutExpr: String?
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
                    case "scenarioTimeout":
                        scenarioTimeoutExpr = arg.expression.trimmedDescription
                        if let seconds = integerLiteralValue(arg.expression), seconds <= 0 {
                            context.diagnose(Diagnostic(
                                node: Syntax(arg.expression),
                                message: FTDSLDiagnostic(
                                    "@Test scenarioTimeout must be a positive number of seconds (got \(seconds))",
                                    id: "scenario-timeout-non-positive")))
                        }
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
                                         scenarioTimeoutExpr: scenarioTimeoutExpr,
                                         deleted: hasDeleted(fn.attributes),
                                         draft: hasDraft(fn.attributes)))
        }
        return result
    }

    /// 整数リテラル(`-5` 含む)の値。リテラルでない式は nil(検査しない = verbatim 転写)
    static func integerLiteralValue(_ expr: ExprSyntax) -> Int? {
        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return Int(String(literal.literal.text.filter { $0 != "_" }))
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
           let literal = prefix.expression.as(IntegerLiteralExprSyntax.self),
           let value = Int(String(literal.literal.text.filter { $0 != "_" })) {
            return -value
        }
        return nil
    }

    /// @TestClass(platform: "...") の引数式を取り出す(式は verbatim 転写)。省略時は "nil"
    static func platformArgument(of node: AttributeSyntax) -> String {
        if let args = node.arguments?.as(LabeledExprListSyntax.self) {
            for arg in args where arg.label?.text == "platform" {
                return arg.expression.trimmedDescription
            }
        }
        return "nil"
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
        let platform = platformArgument(of: node)
        let methods = scenarioMethods(in: declaration, context: context)
        // 診断は extension ロールの1箇所だけで出す(peer ロールでも出すと同じ警告が2回出る)
        diagnoseRenamedLifecycle(in: declaration, context: context)
        SharedStateDiagnostics.diagnose(
            SharedStateDiagnostics.findings(in: declaration, className: className,
                                            testMethods: Set(methods.map(\.name))),
            in: context)
        // クラスに @Deleted が付いていれば全シナリオが削除済み扱い
        let classDeleted = hasDeleted(cls.attributes)
        // クラスに @Draft が付いていれば全シナリオが実装中扱い
        let classDraft = hasDraft(cls.attributes)

        // beforeAll/setUpDevice/beforeEach/afterEach があれば run クロージャに織り込む。ftRunBeforeAll/ftRunSetUpDevice/ftRunBeforeEach/ftRunAfterEach で
        // 包むのは記録のセクション分けと、失敗時の扱い(beforeEach 失敗=シナリオ中断 / afterEach=失敗後も実行)のため。
        // setUpDevice を走らせるかは実行時に親が決める(ftRunSetUpDevice が core.runSetUpDevice を見る)。
        // beforeAll も同じ(ftRunBeforeAll が core.runBeforeAll を見る。run 全体で1回)。
        // 順序は beforeAll → setUpDevice → beforeEach → 本体 → afterEach
        let hasBeforeAll = hasLifecycleMethod("beforeAll", in: declaration)
        let hasSetUpDevice = hasLifecycleMethod("setUpDevice", in: declaration)
        let hasBeforeEach = hasLifecycleMethod("beforeEach", in: declaration)
        let hasAfterEach = hasLifecycleMethod("afterEach", in: declaration)
        // tearDownDevice はシナリオの run クロージャに入れない(親が専用の子で呼ぶ。Descriptors.swift の欄)
        let hasTearDownDevice = hasLifecycleMethod("tearDownDevice", in: declaration)
        let tearDownDeviceArg = hasTearDownDevice
            ? ",\n            tearDownDevice: { let ftInstance = \(className)(); "
              + "FTDSL.ftRunTearDownDevice { ftInstance.tearDownDevice() } }"
            : ""
        // afterAll も run クロージャに入れない(親が run の最後に専用の子で呼ぶ。Descriptors.swift の欄)
        let afterAllArg = hasLifecycleMethod("afterAll", in: declaration)
            ? ",\n            afterAll: { let ftInstance = \(className)(); "
              + "FTDSL.ftRunAfterAll { ftInstance.afterAll() } }"
            : ""
        let entries = methods.map { m in
            let deletedArg = (classDeleted || m.deleted) ? "\n                deleted: true," : ""
            let draftArg = (classDraft || m.draft) ? "\n                draft: true," : ""
            // ライフサイクル無しのときは 1 式のまま(生成コードを増やさない)
            var body = "\(className)().\(m.name)()"
            if hasBeforeAll || hasSetUpDevice || hasBeforeEach || hasAfterEach {
                body = "let ftInstance = \(className)(); "
                if hasBeforeAll { body += "FTDSL.ftRunBeforeAll { ftInstance.beforeAll() }; " }
                if hasSetUpDevice { body += "FTDSL.ftRunSetUpDevice { ftInstance.setUpDevice() }; " }
                if hasBeforeEach { body += "FTDSL.ftRunBeforeEach { ftInstance.beforeEach() }; " }
                body += "ftInstance.\(m.name)()"
                if hasAfterEach { body += "; FTDSL.ftRunAfterEach { ftInstance.afterEach() }" }
            }
            let platformArg = m.platformExpr.map { "\n                platform: \($0)," } ?? ""
            let timeoutArg = m.scenarioTimeoutExpr.map { "\n                scenarioTimeout: \($0)," } ?? ""
            return """
                        FTDSL.FTScenarioDescriptor(
                            name: \(literalString(m.name)),
                            title: \(m.titleExpr ?? "\"\""),\(deletedArg)\(draftArg)\(platformArg)\(timeoutArg)
                            run: { \(body) }),
            """
        }.joined(separator: "\n")

        let ext = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): FTDSL.FTTestClassDefinition {
                public static var ftDescriptor: FTDSL.FTTestClassDescriptor {
                    FTDSL.FTTestClassDescriptor(
                        className: \(raw: literalString(className)),
                        platform: \(raw: platform),
                        scenarios: [
            \(raw: entries)
                        ]\(raw: tearDownDeviceArg)\(raw: hasBeforeAll ? ",\n            hasBeforeAll: true" : "")\(raw: afterAllArg))
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

// MARK: - @Draft(実装中マーカー。@TestClass 側が読むだけで何も生成しない)

public struct DraftMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(ClassDeclSyntax.self) || declaration.is(FunctionDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: FTDSLDiagnostic(
                    "@Draft can only be attached to a test class or a @Test method",
                    id: "draft-target")))
            return []
        }
        return []
    }
}
