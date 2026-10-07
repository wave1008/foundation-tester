# 残件(未解決の不具合の候補)

バグ出し(2026-09-06・09-08・09-11)で見つかり、まだ直していない項目の一覧。台帳は削除したので、
未解決の項目だけをここに残す。**判定は 2026-10-07 の HEAD(c87b8c8f)のソースを読んだ結果で、デバイスでの再現はしていない**。
「(推測)」は、症状の経路か指摘の対象をコードから推して特定したもの。

直したら項目を消す(経緯はコミットに残す)。新しい残件は同じ形(症状・場所・手がかり)で足す。

## 再現の材料が要るもの(材料が無いまま直すと定数か推測を持ち込む)

- **Compose・Flutter では、DSL / ft_batch の `type` / `clearInput` が入力欄でない要素を先にタップし得る**(09-11 §19.2)
  - 症状: ネイティブ描画は撃つ前に断る(`StepExecutor.nonTextInputPreflightRefusal`)。自前描画では本物の入力欄が `button` 等で
    報告されうるので型名で断れず、MCP の ft_type(`TypeReadback.isTextInput` で断る)と判断が割れたまま
  - 要る材料: 自前描画で本物の入力欄が入力型以外で報告される実例(どのエンジン・どの部品か)。iOS は in-app がテキスト入力の trait、
    XCUITest が elementType で入力型を付けるので、残るのは Android の自前描画か id が包みに付く形のどちらか。実例が取れれば、
    その経路が申告する「編集できる」の印(Android の `isEditable`)をブリッジから運んで断る根拠にする
- **文字だけが描画されない Simulator を検知できない**(09-06)
  - 症状: 木は正常でも絵に文字が1つも出ずタイマーも進まないデバイスを凍結と判定できず、シナリオの赤としてだけ残る
  - 場所: `Sources/FTCore/FrozenVerdict.swift`(根拠の6種にこの形が無い)
  - 要る材料: この状態のスクショと木の組(1件も保存されていない)。それが無いと「どれも読めない」の閾値に根拠が置けず、
    既存コーパスでの誤検知0も示せない。取れたら、ラベルを持つ要素の領域を OCR で読む案を警告(`isConclusive=false`)から入れ、
    `FrozenInjection` で陽性対照を通す
- **iOS で SpringBoard の上部バナーの裏を無警告で撃つ**(09-11・推測)
  - アプリ自身の別ウィンドウ(全画面モーダル)は両エンジンとも木に載る(in-app は `visibleWindows` を手前順に撮る・XCUITest は
    アプリの全窓)ので遮蔽の判定に掛かる。SpringBoard のダイアログの注記は `/systemalert` の答えで出し分けるようにした
    (`MCPServer.systemDialogHint(engine:probe:)`)
  - 要る材料: 通知バナーが出ている間の SpringBoard の木(どの目印で見分けられるか)。取れたら `/systemui/covering` の目印に足す
- **キーボードで押し上げられてステータスバーの下に入った要素を、done のまま外す**(09-11・推測)
  - 場所: ステータスバーの帯を見る判定が MCP・`TapTargetGeometry`・`RefGuard` のどこにも無い
  - 要る材料: 実例の木。ステータスバーの高さは木に載らない(画面の枠だけ)ので、定数で帯を決めると機種で黙って誤る。
    ブリッジが安全領域(safeAreaInsets / WindowInsets)を申告する形なら根拠のある判定になる
- **WebView の通常の行間で `webViewGapNote` が出る**(09-11・推測)
  - 場所: `Sources/FTCore/TreeCoverage.swift`(8%・長辺の 5%)。再現した画面が分からず、今も発火するかは未確認。
    コーパスで発火する4画面は真陽性と確かめてある(`NoteCoverageTests` の coverage 表の注記)。要る材料は誤発火した画面の木

## 判断できない・確かめ方だけあるもの

- **焦点救済の例示が別の欄を指す**(09-11 M16): どの文言を指した指摘か特定できない。今の注記
  (`MCPServer+ScreenTools.swift:210-221`)は実際に送った欄を名指ししている
- **シートのヒントが普通のリストでも出うる**(09-11 M10・推測): bf07926c で「容器の下端が画面下端に接し、上端が上から 1/4 より下」
  に絞った(`Sources/FTCore/StepExecutor+ScrollSearch.swift:13-39`・:722-729)。この形の普通のリストでは今も出うる
- **実物の 45 秒級 snapshot で SlowSnapshotBudget が効くことは未確認**(09-08): 注入(`FT_FAKE_SNAPSHOT_DELAY_MS=65000`)でしか
  確かめていない。修正後の実物の最大は 32 秒。結果 JSON に `slow-snapshot` かつ `snapshotMs` ≥ 45000 のステップが出たら、
  120 秒の打ち切りでなく中身のある失敗で終わっているかを見る(`Sources/FTCore/SlowSnapshotBudget.swift:23`)

## 設計判断で据え置いているもの(直さないと決めた。症状が出たら見直す)

- `activateSnapshotNode` の古い木: 撃つ前に `isReachable` で照合するが、UIView まで辿れないノードは許可する
  (`InAppBridge.swift:776-777`)ので、SwiftUI の AX だけのノードでは古いノードが発火し得る
- `InAppSettle` は keyWindow だけを見る(`InAppSettle.swift:91-99`)。別の窓のアニメは見ない
- CLI の `tap --ref` が画面外でも ✅: CLI の tap は状態を持たず、撮り直すと ref が振り直されて利用者が見た番号の意味が変わる
- dry-run の `--device` の黙殺: 機械ごとの子 run へ渡す内部向けのフラグで、断ると内部の経路を壊しうる
- `api bridge-sources` の平文・`remote status --json` の `"-"`・引数なし `doctor` のブリッジ停止: 仕様どおり
- I4 の DSL 側(XCUITest の DSL で ref を撃つと XCTest が拒否ボタンを押す)・DSL の tap のキーボード下: 断るのは MCP だけと決めた
