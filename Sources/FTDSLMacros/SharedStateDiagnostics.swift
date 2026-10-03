// @TestClass のプロパティで「別プロセスで走る部分」の間の値の受け渡しを試みている形を警告する(TestClassMacro が呼ぶ)。
// 各 @Test は別プロセスで、setUpDevice はデバイスで最初の @Test のプロセスの中、tearDownDevice は専用のプロセスで走る
// (ScenarioHost / RunDeviceSession)。同じプロセスで後に走る部分にだけ値が見える(visible(write:read:))。
// **出れば正しい側だけの検知**: 見るのはライフサイクル4つと @Test の本体での `x = …` / `x += …` / `self.x` / `Self.x` だけ。
// ヘルパー関数・メソッドによる変更(`x.append`)・ファイル直下のグローバルは拾わない(拾うと誤検知が増える)。

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

enum SharedStateDiagnostics {

    enum Role: Hashable {
        case setUpDevice, tearDownDevice, beforeEach, afterEach
        case test(String)

        var display: String {
            switch self {
            case .setUpDevice: return "setUpDevice()"
            case .tearDownDevice: return "tearDownDevice()"
            case .beforeEach: return "beforeEach()"
            case .afterEach: return "afterEach()"
            case .test(let name): return "\(name)()"
            }
        }
    }

    struct Finding {
        let property: String
        let writer: Role
        let readers: [Role]
        /// 警告を付ける位置(writer の中の最初の書き込み)
        let node: Syntax

        var message: String {
            "`\(property)` is written in \(writer.display) but read in "
                + readers.map(\.display).joined(separator: ", ")
                + ": \(reason). Share the value with writeMemo / readMemo"
        }

        private var reason: String {
            switch writer {
            case .setUpDevice:
                return "setUpDevice() runs only before the first @Test that lands on each device, in that test's"
                    + " process, so the other tests do not see it"
            case .tearDownDevice:
                return "tearDownDevice() runs in a process of its own after the device has finished its tests"
            case .afterEach:
                return "afterEach() runs after its test, and the next test starts in a new process"
            case .beforeEach, .test:
                if readers.allSatisfy({ $0 == .tearDownDevice }) {
                    return "tearDownDevice() runs in a process of its own after the device has finished its tests"
                }
                return "every @Test runs in its own process, so the value does not carry over"
            }
        }
    }

    /// write で書いた値が read から見えるか = 同じプロセスで read が write の後に走る。
    /// setUpDevice → 他は「最初の @Test だけ」なので見えない側に倒す(他の @Test は確実に見えない)
    static func visible(write: Role, read: Role) -> Bool {
        if write == read { return true }
        switch (write, read) {
        case (.beforeEach, .test), (.beforeEach, .afterEach), (.test, .afterEach): return true
        default: return false
        }
    }

    static func findings(in declaration: some DeclGroupSyntax, className: String,
                         testMethods: Set<String>) -> [Finding] {
        let properties = storedVarNames(in: declaration)
        guard !properties.isEmpty else { return [] }
        var writes: [String: [(role: Role, node: Syntax)]] = [:]
        var reads: [String: [Role]] = [:]
        for member in declaration.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self), let body = fn.body,
                  let role = role(of: fn, testMethods: testMethods) else { continue }
            let collector = AccessCollector(properties: properties, className: className, body: body)
            for (name, node) in collector.firstWrites where writes[name]?.contains(where: { $0.role == role }) != true {
                writes[name, default: []].append((role, node))
            }
            for name in collector.reads where reads[name]?.contains(role) != true {
                reads[name, default: []].append(role)
            }
        }
        var result: [Finding] = []
        for (name, writers) in writes.sorted(by: { $0.key < $1.key }) {
            // 読む側に見える書き込みが1つでもあれば(beforeEach で初期化・自分で書いてから読む)、他の部分の
            // 書き込みを当てにしていない —— そこで出すと「beforeEach で初期化し各テストで書き換える」が誤検知になる
            let orphanReaders = (reads[name] ?? []).filter { reader in
                !writers.contains { visible(write: $0.role, read: reader) }
            }
            for writer in writers {
                let unseen = orphanReaders.filter { !visible(write: writer.role, read: $0) }
                if !unseen.isEmpty {
                    result.append(Finding(property: name, writer: writer.role, readers: unseen, node: writer.node))
                }
            }
        }
        return result
    }

    static func diagnose(_ findings: [Finding], in context: some MacroExpansionContext) {
        for finding in findings {
            context.diagnose(Diagnostic(
                node: finding.node,
                message: FTDSLDiagnostic(finding.message, id: "property-not-shared", severity: .warning)))
        }
    }

    /// ライフサイクル4つ(引数なし)と @Test だけ。ヘルパー関数はいつ呼ばれるか分からないので対象外
    private static func role(of fn: FunctionDeclSyntax, testMethods: Set<String>) -> Role? {
        let name = fn.name.text
        if testMethods.contains(name) { return .test(name) }
        guard fn.signature.parameterClause.parameters.isEmpty else { return nil }
        switch name {
        case "setUpDevice": return .setUpDevice
        case "tearDownDevice": return .tearDownDevice
        case "beforeEach": return .beforeEach
        case "afterEach": return .afterEach
        default: return nil
        }
    }

    /// 格納型の `var`(インスタンス・static とも)。`let` は全プロセスで同じ値になるので対象外。
    /// get を持つ計算プロパティは値を持たないので除く(willSet / didSet だけなら格納型)
    static func storedVarNames(in declaration: some DeclGroupSyntax) -> Set<String> {
        var names: Set<String> = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.tokenKind == .keyword(.var) else { continue }
            for binding in variable.bindings {
                guard let id = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if let accessors = binding.accessorBlock?.accessors {
                    switch accessors {
                    case .getter: continue
                    case .accessors(let list):
                        if list.contains(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) }) { continue }
                    }
                }
                names.insert(id.identifier.text)
            }
        }
        return names
    }
}

/// 1つのメソッド本体の中の、プロパティへの書き込み(最初の1つの位置)と読み出し
private final class AccessCollector: SyntaxVisitor {
    private let properties: Set<String>
    private let className: String
    /// 本体の中で同名のローカル(let/var・クロージャ引数・for/if let)を宣言していたら、素の名前は追わない(self. は追う)
    private var shadowed: Set<String> = []
    /// `x = …` の左辺(読み出しに数えない)
    private var assignedTargets: Set<SyntaxIdentifier> = []
    private(set) var firstWrites: [(String, Syntax)] = []
    private(set) var reads: Set<String> = []

    init(properties: Set<String>, className: String, body: CodeBlockSyntax) {
        self.properties = properties
        self.className = className
        super.init(viewMode: .sourceAccurate)
        shadowed = LocalNames.collect(in: body).intersection(properties)
        walk(body)
    }

    private static let compoundAssignments: Set<String> = [
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&&=", "||=", "??=",
    ]

    /// 参照式がプロパティを指すならその名前
    private func property(_ expr: ExprSyntax) -> String? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            return properties.contains(name) && !shadowed.contains(name) ? name : nil
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self) {
            let baseName = base.baseName.text
            let name = member.declName.baseName.text
            if ["self", "Self", className].contains(baseName), properties.contains(name) { return name }
        }
        return nil
    }

    private func noteWrite(_ name: String, at node: Syntax) {
        if !firstWrites.contains(where: { $0.0 == name }) { firstWrites.append((name, node)) }
    }

    /// マクロの入力は演算子が畳まれていない(`a = b` は SequenceExpr の [a, =, b])
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() where index > 0 {
            let lhs = elements[index - 1]
            if element.is(AssignmentExprSyntax.self) {
                if let name = property(lhs) {
                    noteWrite(name, at: Syntax(lhs))
                    assignedTargets.insert(lhs.id)
                }
            } else if let op = element.as(BinaryOperatorExprSyntax.self),
                      Self.compoundAssignments.contains(op.operator.text), let name = property(lhs) {
                noteWrite(name, at: Syntax(lhs))
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let isAssignment = node.operator.is(AssignmentExprSyntax.self)
        let isCompound = node.operator.as(BinaryOperatorExprSyntax.self)
            .map { Self.compoundAssignments.contains($0.operator.text) } ?? false
        if isAssignment || isCompound, let name = property(node.leftOperand) {
            noteWrite(name, at: Syntax(node.leftOperand))
            if isAssignment { assignedTargets.insert(node.leftOperand.id) }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if !assignedTargets.contains(node.id), let name = property(ExprSyntax(node)) { reads.insert(name) }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // `obj.x` の x(別の物のメンバ)と `self.x` の x は MemberAccess 側で扱う
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.declName.id == node.id {
            return .visitChildren
        }
        if !assignedTargets.contains(node.id), let name = property(ExprSyntax(node)) { reads.insert(name) }
        return .visitChildren
    }
}

/// 本体の中で宣言されたローカルの名前(素の参照がプロパティではなくそちらを指しうるもの)
private final class LocalNames: SyntaxVisitor {
    private var names: Set<String> = []

    static func collect(in body: CodeBlockSyntax) -> Set<String> {
        let visitor = LocalNames(viewMode: .sourceAccurate)
        visitor.walk(body)
        return visitor.names
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        names.insert((node.secondName ?? node.firstName).text)
        return .visitChildren
    }
}
