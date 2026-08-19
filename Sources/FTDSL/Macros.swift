// ユーザー向けアノテーション(マクロ)の宣言。実装は FTDSLMacros ターゲット。
//
// @TestClass
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
///
/// 対象アプリは既定で**実行プロファイル**(runs/<name>.json → apps/<name>.json の
/// `<platform>.app`)から解決される。`app:` は書かなくてよく、書いた場合はそちらが勝つ
/// (1プロジェクトに複数アプリのシナリオが混在する構成のための上書き。食い違いは警告が出る)。
///
/// 同じクラスに `func setUp()` / `func tearDown()`(引数なし・非async・非throws)を書くと、
/// 各 @Test の前後で自動実行される(基底クラスからの継承は見ない)。
/// setUp の失敗はそのシナリオを中断し、tearDown は**失敗後でも実行される**。
@attached(extension, conformances: FTTestClassDefinition, names: named(ftDescriptor))
@attached(peer, names: prefixed(__FTReg_))
public macro TestClass(app: String? = nil, platform: String? = nil) =
    #externalMacro(module: "FTDSLMacros", type: "TestClassMacro")

/// シナリオメソッドに付与するマーカー。
/// メソッドは引数なし・非async・非throws で宣言する(命名慣習: S0010, S0020, …)。
///
/// `platform:`("ios" / "android")を書くとそのOSでだけ実行され、他方の OS の run では
/// **skipped(対象外)として記録される**(失敗ではない)。クラス全体に効かせるなら
/// `@TestClass(platform:)`。両方あるときはメソッド側が勝つ。
@attached(peer)
public macro Test(_ title: String = "", platform: String? = nil) =
    #externalMacro(module: "FTDSLMacros", type: "TestMacro")

/// 論理削除マーカー。テストクラスまたは @Test メソッドに付与する。
/// 削除済みシナリオは一覧に残るが一括実行からは除外される(ID 明示指定なら実行可)。
/// 復活はアノテーションを外すだけでよい。
@attached(peer)
public macro Deleted(_ comment: String = "") =
    #externalMacro(module: "FTDSLMacros", type: "DeletedMacro")
