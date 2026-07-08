// Macros.swift
// ユーザー向けアノテーション(マクロ)の宣言。実装は FTDSLMacros ターゲット。
//
// @TestClass(app: "com.example.sampleapp")
// class ログインテスト {
//     @Test("ログインとエラー表示")
//     func S0010() { scenario { scene(1) { ... } } }
// }
//
// マクロは糖衣であり、FTTestClassDefinition conformance と __FTReg_ 登録クラスを生成するだけ。
// 展開トラブル時は同じものを手書きしても動く。

/// テストクラスに付与する。@Test メソッドを走査してシナリオ一覧を生成し、
/// objc ランタイム発見用の登録クラス(__FTReg_<クラス名>)を追加する。
/// 付与先クラスには引数なし init() が必要(シナリオ毎に新しいインスタンスが作られる)。
@attached(extension, conformances: FTTestClassDefinition, names: named(ftDescriptor))
@attached(peer, names: prefixed(__FTReg_))
public macro TestClass(app: String, platform: String? = nil) =
    #externalMacro(module: "FTDSLMacros", type: "TestClassMacro")

/// シナリオメソッドに付与するマーカー(Shirates の @Test 相当)。
/// メソッドは引数なし・非async・非throws で宣言する(命名慣習: S0010, S0020, …)。
@attached(peer)
public macro Test(_ title: String = "") =
    #externalMacro(module: "FTDSLMacros", type: "TestMacro")

/// 論理削除マーカー(Shirates の @Deleted 相当)。テストクラスまたは @Test メソッドに付与する。
/// 削除済みシナリオは一覧に「削除済み」として残り(GUI は非表示切替可)、
/// 全実行などの一括実行から除外される。ID を明示指定すれば実行は可能。
/// コードを消さずに履歴として残せるため、復活はアノテーションを外すだけでよい。
@attached(peer)
public macro Deleted(_ comment: String = "") =
    #externalMacro(module: "FTDSLMacros", type: "DeletedMacro")
