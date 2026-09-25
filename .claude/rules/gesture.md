---
paths:
  - "Runner/**/CoordinatePinch.swift"
  - "Sources/FTCore/Pinch*.swift"
  - "Sources/FTCore/PinchGesture.swift"
  - "Sources/FTCore/PinchRegion.swift"
  - "Tests/FTCoreTests/PinchGestureTests.swift"
  - "Tests/FTCoreTests/PinchRegionTests.swift"
---

# ピンチ・座標ジェスチャ の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **対象未指定のピンチをどこへ当てるかは `FTCore.PinchRegion` の1箇所**(DSL・MCP・ライブ操作が
  共有する)。**指の2点が別々のものに載るとピンチにならない** —— XCTest のピンチは
  **縮小だけ枠の長辺の両端から閉じる**ので、端に手前のものが載っていると1本を取られ、
  ジェスチャがパンに化ける(実測 2026-09-22・Apple マップ。→ maintainer-notes §41)。
  守る規律4つ: **①両方の指が同じものに載る位置を探す**(置けなければ半径を狭め、それでも
  駄目なら画面矩形を渡す —— **nil にしない**。領域さえあれば座標で撃てて端ちょうどは避けられる。
  3経路で揃える)/ **②指は原則 横に並べる**(縦に並べると同時に効いている
  縦スクロールの recognizer が指を取る)/ **③指の座標は `FTCore.PinchGesture` が唯一の定義元**
  (OS ごとの規則。host 側の1箇所で決め、ブリッジは受け取った座標を再生するだけ)。同じ規則の
  端の閉じ幅を確かめる外側チェックは `closingTouchPoints`(同じモジュール)/
  **④領域を渡すのは iOS だけ** —— Android は領域の**短辺**から指の幅を決めて中心に置くので、
  狭い領域だと最小スケール幅(27mm)に届かない
- **座標ピンチは非公開 API**(`XCPointerEventPath` / `XCSynthesizedEventRecord`。
  **`XCUI` 接頭辞は付かない**・公開ヘッダに宣言が無い。ユーザー決定 2026-09-22 ——
  公開 API に代替が無いことを実測で確かめてから採用した)。`Runner/.../CoordinatePinch.swift` の
  1箇所に閉じ、守る規律3つ: **①実行時に存在を確かめてから使う**(無ければ要素ピンチへ縮退し、
  注記で必ず言う)/ **②起動時にも1行出す**(`coordinate pinch/gesture/doubletap: available` —— 消えたことが
  run を待たずに分かる)/ **③completion ブロックは引数を宣言しない**(実際は先頭に BOOL が来るので
  `(Error?) -> Void` で受けると Swift の thunk が 1 を objc_retain して落ちる)。**`/gesture`
  (DSL の `gesture` / MCP の `ft_gesture`)も同じファイル・同じ非公開 API を使う** ——
  こちらは要素ピンチのような縮退先が無いので、この API が無い Xcode では **422**(501 ではない。
  501 はホストに「このエンジンでは不可」= XCUITest へのフォールバック判定と読まれ、ランナー自身の
  501 は `hideKeyboard` 専用)で断る
