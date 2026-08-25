// ft_batch の引数キーは3つの型表(stringKeys / intKeys / doubleKeys)で解釈される。
// **表は手書きで、ビルダにキーを足したときに載せ忘れても何もエラーにならない** ——
// 気づけるのは、その引数を書いた行が実行時に "does not accept" で弾かれたときだけ
// (2026-08-10 に rotateTo の orientation で実際に踏んだ)。ここで漏れと重複を機械的に落とす。

import XCTest
@testable import fleetest_mcp

final class BatchKeyTypeCoverageTests: XCTestCase {

    private var typeTables: [String: Set<String>] {
        ["string": BatchStepResolver.stringKeys,
         "int": BatchStepResolver.intKeys,
         "double": BatchStepResolver.doubleKeys]
    }

    /// ビルダが読むと宣言したキーは、必ずどれか1つの表に載っていること
    func testEveryBuilderDeclaredKeyHasAType() {
        let typed = typeTables.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        for (command, builder) in MCPServer.batchStepBuilders {
            for key in builder.keys where !typed.contains(key) {
                XCTFail("\(command) が読む \"\(key)\" が型表に無い —"
                    + " BatchStepResolver の stringKeys / intKeys / doubleKeys のどれかに足すこと")
            }
        }
    }

    /// 2つの表に同じキーがあると、どちらで解釈されるかが読み手に決められない
    func testTypeTablesDoNotOverlap() {
        let names = Array(typeTables.keys).sorted()
        for i in names.indices {
            for j in names.indices where j > i {
                let overlap = typeTables[names[i]]!.intersection(typeTables[names[j]]!)
                XCTAssertTrue(overlap.isEmpty,
                              "\(names[i]) と \(names[j]) が同じキーを持つ: \(overlap.sorted())")
            }
        }
    }
}
