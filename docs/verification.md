# 検証の詳細と落とし穴

CLAUDE.md「ビルド・検証」からの詳細分。コマンドと最重要ゲートは CLAUDE.md 側に残し、
ここには**頻度は低いが踏むと痛い罠と判定規律**を置く。読者は保守者(Claude Code)。

## iOS ランナー(Runner/)の再ビルドは供給時に自動化済み(2026-07-28)

`BridgeProvisioner.prepareSharedBuilds` はランナーのソース
(`Runner/FTesterRunnerUITests/`・`Runner/FTesterRunnerApp/`・`Runner/project.yml`・
共有 DTO の `Sources/FTCore/BridgeDTO.swift`)が xctestrun より新しければ
build-for-testing を自動で再実行する(`BridgeLauncher.runnerNeedsRebuild`。
InAppLauncher.needsBuild と対の mtime 判定)。稼働中の旧ランナーは
`BridgeAPI.bridgeProtocolVersion` の /status 照合(xcuitest・inapp とも)で停止→立て直される。
以前は「xctestrun が在れば build を飛ばす」実装で、Runner 変更後に旧ランナーが起動し続ける罠が
あった(2026-07-26 に isChecked 追加で実害・2026-07-28 に /pressEnter 追加で再発し自動化)。
**Xcode/SDK の更新も検知する**(2026-07-29): 判定にツールチェーンの指紋
(`xcodebuild -version` + iphonesimulator SDK ビルド版。`ToolchainFingerprint`)を含め、
成果物の隣(`<DerivedData>/.toolchain`・`InAppBridge/build/.toolchain`)に記録する。
**Xcode を上げてもソースの mtime は動かない**ため、これが無いと旧 Xcode のランナー/旧 SDK の
dylib が使われ続ける(macOS・Xcode がベータのうちは頻発する)。in-app dylib
(`InAppLauncher.needsBuild`)も同じ判定。

**残る罠**: mtime 判定なので、`git checkout` 等でソースの mtime が動かない巻き戻しは検知できない。
疑わしいときは従来の手動手順が今も有効:

```
ftester bridge down --all --platform ios
find .ftester/DerivedData -name "*.xctestrun" -delete
ftester bridge up --platform ios --device <名前>     # ここで再ビルドが走る
```

(Android ブリッジ側は versionCode 照合で自動再インストールされるため、この問題は iOS 側だけに出る)

## in-app エンジンは `--ios-inapp` を付けないと1本も回らない

`Scripts/e2e.sh` の iOS は既定で **`ios-xcuitest` プロファイルだけ**を回す。一方
**利用者の既定エンジンは hybrid(in-app 優先)**(`RunProfile` の `iosInappEngine ?? true`)なので、
既定の E2E は「利用者が普段通らない経路」しか見ていない。in-app ブリッジ(入力・スナップショット・
型写像・ジェスチャ申告)を触ったら **`Scripts/e2e.sh --ios-inapp`** を追加で回すこと。

## 入力・キー系は Compose だけで検証しない(フレームワークで経路が割れる)

Compose の入力欄は独自のキーイベント処理を持つため、**他フレームワークで死んでいる経路でも緑になる**。
実害(2026-07-28): Android の `pressEnter` はソフトキーボードが出ていると `keyevent 66` が
View/XML の `EditText` に届かない(IME が消費する)のに、CMP SUT の E2E は通っていた。
E2E-Android(View/XML)を回して初めて赤くなり、a11y の `ACTION_IME_ENTER` 経路へ作り直した
(design.md §実装で得た知見)。**入力・キー・IME 系を触ったら E2E-Android と E2E-iOS を必ず含める**。

## flake・性能の判定規律(1回の結果で断じない)

- **flake の修正は「1回グリーン」で判定しない**。flake は確率的で、低負荷なら偶然通る。
  確認は**反復+負荷**で叩く(該当シナリオ単独 ×10、または該当プロファイルをフル並列で **×10**)。
  **単独実行では出ないことがある**(2026-07-31: 8台並列のフルスイートで約40%出る flake が、
  同じシナリオの単独反復では8回中0回だった。負荷そのものが条件)。
  実害: 「v10 で直した・10連続グリーン」と報告した直後にフル並列で再発し、修正コードが**実際には
  実行されていなかった**と判明した(2026-07-23。type(ref) をホスト側で tap+ref:nil に分解していて
  ブリッジの ref 経路に到達していなかった)
- **修正を入れたら、その修正コードが実行される経路か確認する**。層をまたぐ実装(ホスト↔ブリッジ、
  driver↔StepExecutor)では上の層が下の層の入力を作り替えていて下の修正が空振りすることがある。
  症状が消えないときは「直したはずの箇所に本当に到達しているか」をログ/ブレークで確かめてから次を疑う
- **flake は「基準値」を測ってから対策を測る**。対策の前後で同じ負荷・同じ周回数を回さないと
  改善したのか揺れたのかが言えない。実害: 「対策で 2/5 に改善」と読んだ数値が、対策を撤去して
  測り直すと素で 5/5 だった(2026-07-31。つまり最初の 2/5 が偶然の当たりで、対策は無関係)。
  **判定は 10 周**まで伸ばす(5 周では 0/5 と 1/10 を区別できない)
- **ブリッジを変えたら版数を上げてから測る**。上げないと稼働中の旧ブリッジが再利用され、
  **修正前のコードを測ってしまう**(2026-07-31 に**同日2度**踏んだ。§ブリッジの版)。
  **見分け方**: 直したはずの症状がそのまま出る / 消したはずの一時診断メッセージがまだ出る。
  後者は決定的で、実際「診断文が応答に残っている」ことで旧 APK 再利用に気付いた。
  iOS の dylib と Android の APK は**版が一致していると再利用される**ので、A/B で
  旧実装を測りたいときも版を進める(下げると Android はインストールを拒否する)
- **「症状が変わった」は前進**。嘘の成功(成功を返すのに値が入っていない)を潰すと、失敗は
  「後続の検証が謎の値で落ちる」から「操作自体が理由付きで落ちる」に変わる。失敗率が同じでも
  原因の特定が可能になるので、まずここを塞ぐ
- **失敗ログは「期待値と実際値」を必ず読む**。今回の根本原因(マスク文字列の書き込み・二重追記)は
  実際値(`password=•••…secret42` / `hello123hello123`)を見て初めて分かった。
  「失敗した/しない」の集計だけを見ていると、**自分の対策が値を壊している**ことに気付けない
- **性能・不具合を1回の観測で断じない**。壁時計はコールドスタートの供給や一過性のブリッジ切断で
  大きく揺れ、どちらも定常性能ではない。各プロファイル 2〜3 回計測して定常値を取る。
  揺れの要因・数値・誤評価の実害事例は docs/performance-tuning.md §7 に集約(数値の更新はそちらで)
- **「この指標が異常個体を表す」は1個体でなく全数で確かめる**。壊れた個体だけを見ると、たまたま
  高い指標が原因に見える。実害: 凍結した1台の Metal エラー増加速度(+148/5分)を見て「速度で
  異常機を特定できる」と結論しかけたが、**フリート8台を集計すると健全機の方が高かった**
  (最大 288/分)。指標が個体を分離できるかは「異常機 vs 健全機」を並べて初めて言える
  (このケースの結論と全数データは performance-tuning.md §7)

## 高負荷では XCUITest の `typeText` が打鍵を取りこぼす(2026-07-31)

`/clear` は「残り文字数ぶんの delete を送る」を繰り返すが、**送った打鍵が全部入る保証はない**。
実測(6シミュレータ並列 + Android スイート並走)では毎周 6 割前後しか入らず、
`"hello123"(8打鍵)→"hel"`、`"hel"(3打鍵)→"h"` と減っていった。周回数を 2 で固定していた頃は
ここで打ち切られ「値が残っています」で落ちていた(**約 2%**。フルスイートでのみ再現し、
該当シナリオ単独では出ない)。**打鍵数ぶん送ったことを完了の根拠にしないこと** —— 読み返して
空になるまで回す(`BridgeRouter.handleClear`。上限は周回数ではなく deadline と進捗なし回数)。

**この手のフレークはシナリオ経由では効率が悪い**。1周(約2分)で clear が数回しか走らず
1/5〜1/11 でしか出ないため、ブリッジを直接叩くハーネス(ホストと同じ
snapshot→ref→/type→/clear の順で6台並列)で 1 回 150〜180 clear を回した。
再現率の比較には**同じ負荷・同じ回数**を使う(修正前 5/270 → 修正後 0/510)。
負荷源は合成 CPU 負荷(`yes`×20)では不十分で、**実際に別スイートを並走させる**必要があった。

**`/type` も同方式で対策済み**(2026-08-01・v29。`BridgeRouter.handleType` + 判定は
`TypeReadback`)。こちらの実害は取りこぼしだけでなく**コミットの遅れ**: `typeText` は
打鍵がアプリの状態に入る前に返り(打鍵はキーボード=別プロセス経由で非同期、タッチは直接届く)、
直後の送信タップが**空の値のまま処理される**(フル E2E 1 回で `type "#field_single"
"persist99"` 成功扱い → 失敗画面は `single=persist99` / `len=9` なのに `submitted=` 空。
= タップ処理の後に打鍵が届いた動かぬ証拠)。実測のコミット遅延は同負荷で通常 40〜80ms、
**まれに 0.6〜1.2s** —— ホストの次リクエストまでの間隙(100〜250ms)を超えるので順序が入れ替わる。
読み返して期待値(入力前の値 + 本文)に一致するまで返さないことで、この窓を構成的に閉じた。

`/type` の対策で踏んだ罠(いずれも実測):
- **要素スコープの `typeText`(`focused.typeText`)を使わない**。イベント合成の失敗が XCTest の
  失敗になり**ランナーごと落ちる**(高負荷で `Synthesize event` を最後にランナーが死んだ実測1件。
  同run では6台中5台が死んだが、残りは下記の SpringBoard 起因と切り分けきれていない)。
  打鍵は従来どおり `app.typeText`
- **読み返しにライブクエリ(`descendants` + `hasKeyboardFocus`)を使わない**。1回 0.5s 級で
  /type の p50 が 842ms → 2,166ms に悪化した。スナップショット(`captureOnce` 数十 ms)で
  読み、対象は直前スナップショットの ref→要素対応から採る(`refElements`)
- **追送の前に「値が動かなくなる」まで待つ**(1.5s)。まだ届いていないだけの欄へ追送すると
  二重入力になる(Android `InputInjector` と同じ罠)。読めない・曖昧(同 identifier が複数)・
  前方一致でない(自動修正・マスク欄)は**検証を諦めて受理**する(嘘の成功は潰すが、
  加工された入力を失敗にしない)。判定の境界は `TypeReadbackTests` が固定する
- **ハーネスで毎周 `launchApp` し直さない**。高負荷での連続再起動は SpringBoard を落とし、
  ランナーの launch 失敗(= XCTest 失敗で死ぬ)を誘発する。warm な画面で入力クリア→type→
  即 submit を回す方が安全で、実際の失敗窓(type 直後のタップ)も正しく突ける
- **ハーネスで酷使した直後の e2e 失敗は、まず沈静化後の再実行で切り分ける**。SpringBoard を
  連続で落とした後のシミュレータは、`launchApp` がアプリの画面状態をリセットしない類の失敗を
  出す(実測: 直後のフル e2e で「起動直後なのに前のシナリオの画面のまま → `#nav_*` を解決
  できない」が 7/40。同一シミュレータで沈静化後に再実行したら 40/40 緑)。修正のせいに
  見えるが環境ダメージ。失敗画面が「ホーム以外」ならまずこれを疑う
- この失敗クラスは**直叩きハーネスでは再現しにくい**(修正前 v28 で計 1,495 type・再現 0。
  シナリオ実測はフル E2E 298 本で 1 回)。窓が「コミット遅延 > ホストの間隙」という
  タイミング条件のため。再現率で判定できないときは、**失敗記録の画面状態から機構を確定し**、
  コミット遅延の実測(上記)で窓の実在を示したうえで、窓を構成的に閉じる修正を選ぶ

**確定判定はまだ**(2026-08-01 時点): 元の発生率が 1/298 本のため、修正直後のフル E2E
全緑(既定 233 + --ios-inapp 115)1回では「直った」と断定できない。以後のフル E2E で
S0030 型(type が成功扱いなのに後段の検証で値が空)の再発ゼロを重ねて確定とする。
再発したら、まず失敗レポートの要素一覧で「入力欄の値」と「echo/submitted」を突き合わせる
(値が入っているのに submitted が空なら別クラス = タップの空振り。下記)。

同型で**未対策のまま残している**もの(再発時はここから疑う):
- **/pressEnter**: 完了(IME アクション発火)を汎用に読み返す先が原理的に無い
  (`#txt_ime_action` は E2E SUT の都合で、実アプリに同等物は無い)。未再現のため記録のみ
- **タップの空振り**: /tap が 200 を返したのにタップが処理されない。計測中に1件だけ観測
  (type→即 submit の直叩き 約1,500 回中 1 回・極端負荷下。入力欄の値は正しいのに
  `submitted=-` が初期値のまま = type ではなくタップ自体が落ちた)。type と違い
  「何が起きるべきだったか」をブリッジが知らないので、同じ読み返し方式は使えない

## in-app の整定が cap に張り付いているかを見る(2026-07-31)

`InAppSettle` は収束しても cap 打ち切りでも**同じ顔で返る**ので、常態的な張り付きは黙って
性能だけを食う(実測: Compose iOS の launch 直後 1〜2 アクションが毎回 2,500ms)。疑う手順:

1. `ftester api run --project <P> --profile <inapp プロファイル> --scenario <1本>` の
   NDJSON で `actionMs` を見る。**cap 値(2500)に近い定数**なら張り付き。
   snapshotMs でも waitMs でもなく actionMs に出るのが目印
2. `InAppBridge/Sources/InAppSettle.swift` の打ち切り分岐に一時 `NSLog("FTSETTLE ...")` を入れ、
   層のクラス名・アニメーションキー・keyPath・delegate を出す(`InAppBridge/build.sh` で再ビルド)
3. `xcrun simctl spawn <udid> log stream --style compact --predicate 'eventMessage CONTAINS "FTSETTLE"'`
   を**プロファイルの全デバイスぶん**張ってから run(どの機に載るか選べないため)
4. 犯人が分かったら `layerAnimating` の除外に足す。**除外は狭く**(位置・不透明度・transform を
   除外すると本物の遷移待ちが壊れる)

**dylib は版を上げないと入れ替わらない**(`bridgeProtocolVersion`)。上げずに測ると旧 dylib の
数字を見ることになる。

## ブリッジの「偽陰性」を疑う手順(成功しているのに失敗と報告される)

**症状**: ステップは失敗するのに、直後にスナップショットを撮ると**期待どおりの状態になっている**。
2026-07-31 の Android WebView `type` がこれで、原因は a11y ノードのキャッシュを取り直さずに
読んでいたこと(値は入っていたが読みが古い)。同型は「キャッシュ・遅延イベント・整定の打ち切り」の
どれかを疑う。

1. **まずホスト側から状態を撮る**。失敗した直後に `/snapshot` を撃ち、期待値になっていれば
   偽陰性が確定する(「入っていない」のか「読めていない」のかはここで分かれる)
2. **シナリオ経由で追わない**。1 run に1回しか通らない操作は再現率が低すぎる
   (実測 111 run で 2 件 = 1.8%)。**ブリッジを直接叩くハーネス**をホストと同じ手順
   (snapshot → ref 解決 → 操作)で書き、全デバイス並列で数十回まわすと同じ事象が
   **20%** まで上がった。負荷は合成 CPU 負荷では足りず、別スイートの並走が要る
3. **ブリッジ側に一時診断を足す**(期限切れの瞬間に何が見えていたか: ノードの有無・text・
   focused・bounds・候補の全列挙)。**版を上げないと旧ブリッジが再利用されて意味がない**
4. 直したら**同じ負荷・同じ回数**で前後比較する(修正前の実測が無いと「効いた」と言えない)

## 単体テストが緑でも「実データで1回動かす」まで信用しない(2026-07-29)

単体テストは**書いた本人の前提を共有している**ので、前提そのものが誤っていると実装とテストが
仲良く同じ誤りを持ったまま緑になる。LPT 投入順の実装(§performance-tuning §3.7)では、
単体テストが全て通っている状態で**実データを1回流すたびに別のバグが出た**:

1. **ワーカー label のパース誤り**。`RunOrchestrator` のコメントが `例: "ios:8123"` のまま古く、
   実際のプロファイル経路は `ProfileWorkerFactory` が作る `"Pixel 9(Android 15)-01(android:emulator-5554)"`。
   **デバイス名自体が `(` と `:` を含む**ため先頭 split が壊れていたが、テストも同じ誤った形式で
   書いていたので気付けなかった。→ 生成と解析を `RunWorker.makeLabel` / `platform(fromLabel:)` に
   集約し、**実形式での往復テスト**で固定した
2. **`RunRecorder.begin` の副作用**。実行中の run のディレクトリが scanRecords の時点で既に存在し
   (中身は空)、履歴枠を1つ食っていた。副作用は別ファイルにあるのでコードを読むだけでは出ない
3. **単一 platform でしか試していなかった**。実績を `scenarioID` だけで集計していたため、同じ
   シナリオを iOS/Android 両方で走らせる構成では中央値が両者の中間へ均されていた

**規律**: 挙動を変えたら、単体テストの緑とは別に**最小構成で1回実行して出力を目で見る**。
特に「別の場所の副作用」「実際の文字列形式」「複数条件の混在」は、テストの前提に取り込まれていて
テストでは出ない。実データを見るコストは数十秒で、見つかるバグは実装の中核であることが多い。

## テストは「通ること」でなく「破ったら落ちること」を確認する(2026-07-29)

新しく書いたテストは、**production 側をわざと壊して落ちるか**を1回確かめる(変異テスト)。
この確認だけで、このセッション中に**無力なテストが4件**見つかった:

- TOOL_ROOT の照合が `foundation-tester` の**接頭辞一致**で、`foundation-tester-RENAMED` を素通し
- 時間集計のアサーションが「nil でないこと」止まりで、壁時計の計算を壊しても通る
- 走査 run 数の上限をテストが既定値のまま呼んでいて、上限を外しても差が出ない
- 同値の安定化を3要素で検証していて、比較器を壊しても偶然順序が保たれる

**やり方**: `cp` で退避 → 1行だけ壊す → テスト実行 → 復元、を数種類。検出できない変異が出たら
**テストを境界へ寄せる**(要素数を増やす・既定値でなく限界値で呼ぶ・観測可能な出力を assert する)。

**検出できないのが正しい場合もある**。Swift の `sorted(by:)` は仕様上は不安定だが実装は安定なので、
同値の安定化を外しても現在の挙動は変わらない(実測: 200要素・同値混在で順序保持)。この種の
「将来への保険」はコメントにその旨を書き、無理にテストを作らない。

## 拡張 webview のテストは jsdom にレイアウトが無い(2026-07-31)

`test/webview*.test.mjs` は実 HTML + 実バンドルを jsdom で動かすが、**jsdom はレイアウトを持たない**
(`clientHeight`/`offsetHeight`/`getBoundingClientRect` は常に 0、`offsetParent` は null)。
そのため「寸法を測って何かを決める」コードは**分岐そのものが1本しか通らず**、緑でも無検証に近い。

- **再現の仕方**: 対象要素に `Object.defineProperty(el, 'clientHeight', { value: N, configurable: true })`
  で高さを与える(実例: `webviewTileRelayout.test.mjs`。表示中=306 / `display:none` 相当=0 を
  切り替えてタブ往復を再現する)
- **見落としの実害**: タイルの auto-fit がタブ復帰後に崩れるバグ(design.md §12.5)は、
  非表示中に届く `devices` が `--tile-image-h` を潰すのが原因で、**全ユニットテストが緑のまま**
  残っていた。jsdom では表示中も非表示中も 0 で区別が付かなかったため
- **併せて**: レイアウト計算そのものは DOM 非依存の純関数へ切り出して単体テストする
  (`tileFitModel.js` ⇔ `tileFitModel.test.mjs`)。DOM 側テストは「実測して純関数へ渡す配線」だけ見る

## 排他は TSan で見る(2026-07-29)

共有状態のロック(`FTDriveCore.stateLock` / `FTRuntime.lock` [契約は docs/design.md §10] や
`DeadlineTaskBox`)を触ったら **`swift test --sanitize=thread`** を通す。
**排他の正しさは目視レビューでは担保できない** — 実際に 2 件、レビューを通り抜けた競合を TSan が
検出した: ①`FTRuntime.shared.core` を tearDown が書き替える裏で違反スレッドが読む
②`RunOrchestrator.withDeadline` の満期 task 参照(**「代入は同期区間で完了するのでレースしない」と
コメントに書いてあったが `Task { }` の本体は囲みの同期区間と並行に開始し得るので成り立たない**)。
通常の `swift test` は緑のまま素通りする。

**2つの罠**:
- **計装バイナリが `.build/debug` に残る**。TSan の後に E2E を回すと、シナリオが全部成功しても
  終了時に `Abort trap: 6` で落ちる(実害あり)。普通に `swift build` し直し
  `otool -L .build/debug/ftester | grep -c tsan` が 0 になることを確認する
- **`Thread.sleep` のポーリング待ちは同期とみなされない**。実際には順序が付いていても
  `As if synchronized via sleep` 付きで報告されることがある(報告を読むときに見分ける)

## 検証スクリプトそのものの罠

- **エラーを保存・表示するときは切り詰める前に入れ子を畳む**。`prefix(N)` で素の description を
  切ると**真因が構造的に落ちる**(最上位は「The operation couldn't be completed.」のような
  定型文で、原因は `NSUnderlyingError` / `NSMultipleUnderlyingErrors` の奥にある)。
  実害: FM の全滅原因が 300 文字の切り捨てで数日間まったく見えなかった(`FMHealth.describe` 参照)
- **pipefail 下で `cmd | head` を条件式・値の取得に使わない**。head が1行読んで先に閉じると
  上流が **SIGPIPE(141)** で死に、pipefail がそれを失敗として拾う。1行目が欲しいだけなら
  変数へ入れてからパラメータ展開で切る(`${out%%$'\n'*}`)。実害: `if x="$(xcodebuild -version | head -1)"`
  が正常な Xcode を `unusable` と判定し、受け手に無関係な license 同意を案内した(2026-07-29)。
  **矛盾する出力は誤判定の兆候**(このときは `xcode=unusable` と `xcode_first_launch=done` が同時に出ていた)
- **zsh は未クォート変数を単語分割しない**。`for x in "a b" "c d"; do set -- $x; ...` は
  bash の感覚だと 2 引数に割れるが zsh では割れず、`$1` に全体が入る。
  実害: SUT×プロファイルの再検証ループが全件「プロジェクトが見つかりません」で空振りした
- **合否を後続コマンドの exit code で潰さない**。`Scripts/e2e.sh > log; echo "EXIT=$?"` のように
  末尾へ何か足すと、**シェル全体の exit code は最後のコマンドのもの**になる。
  バックグラウンド実行の完了通知もそれを見るため「exit 0」と報告されるのに
  中身は `❌ E2E に失敗があります` という食い違いが起きる(2026-07-27 に実際に誤読した)。
  `$?` を表示したいなら**その値でそのまま終わる**(`exit "$?"`)か、ログの `❌` 行で判定する
- **E2E の実行中に `swift build` しない**。走っているランナーの実行ファイルを差し替えると
  プロセスが **SIGKILL** される(`Scripts/e2e.sh: ... Killed: 9`)。シナリオの失敗と紛らわしいので、
  検証中はビルドを挟まない(2026-07-27 に実際に踏み、Flutter の profile が丸ごと落ちた)
- **`log` は絶対パスで叩く**(`/usr/bin/log`)。shell 関数に食われて
  「too many arguments」になる。さらに**自分の述語文字列が `log` プロセス自身のログに出て
  偽の一致行になる**ので、必ずプロセス名まで確認する

## 操作は ✅ なのに画面が変わらないとき

`tap` がエラーにならず成功として記録され、次の検証だけが「期待と違う」で落ちる形。
**ロケータの問題ではない**ので、セレクタを直そうとすると時間を溶かす。既知の原因は2つ。

1. **アプリが別プロセスの window に覆われている**(システムダイアログ・IME の案内・通知シェード)。
   アプリの a11y ツリーには他プロセスの window が出ないため、要素一覧は正常に見える。
   **2026-07-27 以降は失敗時に自動で警告が出る**(コンソールとレポート。
   `⚠️ アプリより手前に別の window があります: …`)。出ていたらこれが第一の容疑
2. **アプリ内メッセージ**(お知らせ・キャンペーンのモーダル)。**同一プロセスなので 1 の検出では
   捕まらない**。こちらは失敗メッセージに `(対象は #… に覆われています)` が付く(幾何判定・FM 不要)。
   繰り返し出るなら `irregularHandler` を宣言して自動で閉じさせる(design.md「割り込みハンドラ」)
3. **スクロール探索の直後**(下記の節)。こちらは修正済みだが、同じ症状の別原因として覚えておく

実例: Gboard の「タッチペンを試してみる」が送信ボタンを覆い、05_テキスト入力 が間欠失敗した
(抑止は `AndroidBridge.disableStylusHandwriting`)。**この手の教育用ポップアップは今後も増える**ので、
1 の警告が出たら SUT ではなくデバイス設定側を疑う。

**切り分けの定石(iOS)**: 同じシナリオを `ios-inapp` プロファイルでも回す。in-app は ref で、
xcuitest は座標でタップするので、**片方だけ落ちるならタップ経路の問題**、両方落ちるならアプリ側か
セレクタの問題と切り分けられる(スクロール直後のタップの機序特定で決め手になった)。

## スクロールした直後のタップ(2026-07-27 修正済み)

スクロール探索(`scrollTo` / `tap(scroll:)`)の直後は、そのまま操作しても**別の要素を掴む(Android)**
**まったく効かない(iOS)**。`StepExecutor` の探索終端で2つの処置を**この順で**行って解消した。
利用者側の書き方は変わらない(回避策を覚える必要はない)。

1. **空打ちの極小ドラッグ(iOS のみ)**: Compose のスクロール容器は次の1タッチを消費してしまい、
   タップもプレスも効かない。クリックにならない 2pt ドラッグでその1回を肩代わりする
2. **静止待ち**: frame が連続2回同じになるまで待つ(最大 600ms・スワイプした周回だけ)

**iOS の空打ちを Android でやってはいけない**: Android では 2pt ドラッグが**クリックとして発火**し、
タップしていないのに行が選択される(= 二重実行)。`releasesScrollTouch` が唯一の分岐理由。

**空打ちは「対象が覆われていないとき」だけ打つ**(2026-07-27)。覆われている点を触ると
**覆っている側が反応する**。実害: E2E-iOS の `#txt_offscreen` はスクロール後に
**タブバーの帯(y 778〜840)の中**へ出るため、空打ちがタブバーに届いてホームタブへ切り替わり、
直後の `exist` が「要素が見つかりません」で **5/5 失敗**した(11:19 の空打ち導入から
E2E-iOS を回すまで気付かなかった)。**距離を伸ばしても・画面端から離しても直らない**
(ドライバの press→release はタップとして届く)。判定は
`StepExecutor.pointIsTakenByFrontElement`(**触る1点**が手前の別要素に入るか。
面積比の `OcclusionSuspicion.covering` では部分的な重なりを取りこぼし、並列実行の
フル E2E でだけ再発した)。

切り分けの記録(同じ実験を繰り返さないために):

| 試したこと | iOS の結果 | 分かること |
|---|---|---|
| `scrollTo` → `tap`(中間行) | ❌ `selected=-` | 現象 |
| `scrollTo` → `wait(2)` → `tap` | ❌ | **時間では解けない**(慣性・アニメーション待ちではない) |
| `scrollTo` → `tap` → `tap` | ✅ | **2回目は届く** = 1タッチが消費されている |
| `scrollTo` → `press` | ❌ | 別ジェスチャでも同じ |
| `scrollTo` → **固定ヘッダ**を `tap` | ✅ | タッチは配送されている。スクロール容器の中だけの問題 |
| **ios-inapp** プロファイル | ✅ 全て | in-app(ref)経路は無傷 = 座標の精度の問題ではない |
| ランナーで **XCUITest クエリ解決**して `element.tap()` | ❌ | **不採用**。届け方を変えても効かない |
| ランナーの整定待ちを 0.35→1.2s | ❌(揺れる) | **不採用**。1回の緑は雑音だった(なお 2026-07-30 にこの固定待ち自体を収束判定へ置換した。performance-tuning.md §3.8) |
| 「画面に収まるまで追加スワイプ」 | ❌ | **不採用**。frame は画面中央に完全表示でクランプではない |

- **既知の残: Android の `#row_25` 付近が確率的に落ちる**(`ロケータを解決できません` /
  スクロール探索自体の失敗)。**変更前から同じ**(ベースライン 3 回中 2 回で再現)なので本件とは別問題。
  フリング中に対象行がリサイクルされて消えるのが疑わしい

## `Scripts/e2e.sh`(ftester 自身の E2E)

- SUT(`E2EApp/` 他)の鮮度を見て必要なら再ビルドし、各プロファイルを順に回す。オプション:
  `--rebuild` / `--ios` / `--android` / `--cmp` / `--ios-native` / `--android-native` / `--flutter` /
  `--ios-inapp`(iOS を in-app エンジンで回す。上記「in-app エンジンは…」節) /
  `--record`(録画パイプラインの整合チェック付き。詳細は下記「録画」節)
- **両OSを1プロファイルにまとめない**: platform 未指定シナリオは既定 platform のキューにしか入らず
  他方のワーカーが空回りする(design.md §11.4)。SUT はネットワーク依存ゼロなのでバックエンド死活の
  切り分けは不要
- **フレームワーク差の退行は SUT を跨がないと出ない**。ブリッジのスナップショット/型写像
  (`SnapshotBuilder`・`BridgeRouter`)を触ったら SUT を絞らず全部回す。片方だけ通って
  もう片方が黙って空振りする類の退行が実際に出る(Compose の Button は `Cell`、View/XML は `Button` 等)

## 受け手フロー(preflight / install.sh)の検証

- **更新は `Scripts/update.sh`**(install.sh を再実行 + `project sync` + プラグイン更新と版照合)。
  clone 構成でこれを回すとき、**受け手向けの整備がクローン自身に効かないこと**を確かめる
  (実害: install.sh の `.gitignore` 追記がリポジトリを dirty にし、次の更新が pull ガードで
  止まる。現在は clone 構成では skip する。`.gitignore` の項目は `ProjectScaffold.ensureGitignore`
  と対 — 片方だけ変えない)
- **クローンを dirty にしたまま `install.sh` を試すと必ず止まる**(ローカル変更の破棄を尋ね、
  端末が無い実行では中止する仕様)。本体を触りながら試すときは **`--no-pull`** を付ける
- 実行の記録は `<WORK_DIR>/.ftester/install-<日時>.log`(実行ごとに別ファイル)。
  端末出力を追わずに後から失敗を追える
- **スキルが渡す新しい引数は、受け手のクローンが pull されるまで存在しない**。
  スキルからは **curl 形**(常に main の最新が走り、その中でクローンを pull する)で呼ぶ。
  実害: `--platform` を渡した初回が「不明なオプション」で落ちた(2026-07-29)
- 個別コマンドを叩いて確かめる前に、**preflight と install.sh の出力に既にあるか**を見る
  (`tool_root=` / `[ok] MCP` / `[ok] ルート解決` / `[ok] プロファイル`)。取り直しは承認回数を増やすだけ

## 常駐プロセスの掃除

- **ディレクトリを消しても `.build` が戻る**のは、生きているプロセスが作り直しているから。復活させる
  主体は MCP の rebuild-on-start(`.mcp.json` が起動のたびに `swift build`)と拡張のパネル respawn。
  **VSCode 終了で止まらないのは XCUITest ランナーだけ**(親から切り離してあり PPID=1)。
  順序と掃除の1行(`pgrep -fl` / `pkill -f`)は docs/getting-started.md「アンインストール」
- 再ビルド後の検証前に旧バイナリの常駐プロセス(monitor/host-metrics)を kill する
  (生き残って検証を汚す・旧ブリッジを自動再起動する。docs/performance-tuning.md §7)
- ブリッジには無通信 TTL(既定2時間。design.md §4.1)があるが、**検証の掃除で TTL を
  当てにしない**(旧版ブリッジには入っていない・モニターのポーリングが心拍になり失効しない)
- **調査で `ftester api monitor` を手で回すときは stdin を開いたままにする**
  (`tail -f /dev/null | ftester api monitor ...`)。**stdin の EOF が終了指示**なので、
  スクリプトからバックグラウンド実行すると /dev/null が即 EOF になり、
  **1行も出さずに正常終了**する(「監視が何も返さない」ように見える罠)

## FM(Foundation Models)が全滅したら

occlusion-guard・自己修復・screenIs は FM 失敗時に nil を返して**素通りする**(呼び出し側が握りつぶす)。
run 終了時の「FM 呼び出しが全て失敗しました」警告と結果 JSON の `fm` フィールドだけが手がかり。

- **切り分けの起点は `ftester doctor`**。availability は「端末が対応しているか」しか見ておらず、
  資産側の理由で全滅していても `available` を返すので、**実呼び出し(checkLive)の結果で判断する**
- **FM 依存の変更は「FM を呼ぶシナリオ」で検証する**。まず前提として、偽陽性検証
  (occlusion-guard)は**実行プロファイル既定 OFF**(`falsePositiveCheck: true` でオプトイン。
  2026-07-28 変更)なので、**E2E の既定プロファイルでは occlusion-guard は一切発火しない** —
  検証時は profile に `falsePositiveCheck: true` を立てること。有効化しても
  `OcclusionSuspicion` が疑いを立てたときだけ発火するので、シナリオを選ばないと `fm: null` で
  **空振りする**(実害: 02_id指定・05_テキスト入力 で2回続けて空振りし、検証したつもりになった)。
  実測で FM 呼び出しが最も多いのは `ジェスチャが正しく検出されること`。
  確認は結果 JSON の `fm` フィールドで行う(警告が出ない = 成功、ではない。**呼ばれていない**かもしれない)
- **実行時の FM 経路は `FMHealth.record` を必ず呼ぶ**(occlusion / heal / screenIs / triage)。記録は
  `fm` フィールドと `FMBreaker` の両方を養うので、欠けると①`fm` に出ず「呼ばれていない」と誤読され
  ②失敗がブレーカを進めず、死んだホストで時間を捨て続ける。実害: **triage が記録を欠いていた**
  (2026-07-30 修正。`fm.calls` に一切現れず、動作確認はレポートの「トリアージ」節でしか取れなかった)。
  監査は `FMAccountingAuditTests`(**関数単位**。ファイル単位だと同一ファイルの heal / screenIs に
  一致して triage の欠落を見逃す。判定前にコメントを落とすのも必須 —
  記録の必要性を説明したコメント自身に一致して一度素通りした)。
  作成時の経路(FMDoctor / ScenarioNamer / TestbaseDrafter)は run の実績ではないので免除リスト
- **ヒールキャッシュが FM を肩代わりする**。`Projects/<p>/.ftester/heal-cache.json` が命中すると
  heal は FM なしで解決し(`healed=1` だが `fm` は nil)、**FM 経路を検証したつもりで空振りする**。
  heal の FM を実際に通すときはこのファイルを消してから実行する

### FM 経路の検証は `Scripts/fm-verify.sh`(2026-07-30)

上記の空振り要因(既定 OFF・失敗しないと呼ばれない・キャッシュ命中・既定スイートに無い)を
まとめて潰す。**FM 専用シナリオを一時的に有効化 → FM 全 ON の `ios-fm` プロファイルで実行 →
結果 JSON の `fm.byKind` に4種が出たかを判定**する(1コマンド)。

```
Scripts/fm-verify.sh                    # 既定 Projects/E2E・プロファイル ios-fm
```

- FM 専用シナリオは `Projects/E2E/Scenarios/_disabled/` に置く(`90_自己修復` = heal /
  `92_screenIs` = screenIs / `93_triage` = **意図的に失敗**して triage を発火)。
  **既定スイートに入れない**: 生きた FM の判定は非決定的でフレーク源になり、
  かつ FM が死んでいる間は skip されるので緑のまま気付けない
- スクリプトは `trap` で必ず `_disabled/` へ戻し、退避したヒールキャッシュも復元する
  (出したままだと既定スイートを汚す)
- `heal` / `screenIs` / `triage` の欠落は失敗扱い。**`occlusion` は疑いが立った時だけ発火する**ので
  警告に留める(呼ばれないことと FM の死を区別できない)
- 実測(2026-07-30・再起動直後): occlusion 13 / heal 2 / screenIs 2 / triage 1 呼び出し・失敗 0。
  **occlusion は `ジェスチャが正しく検出されること` が大半**(docs の「最も呼ばれる」の裏取り)
- **occlusion-guard は長期間 死んだままでも E2E は緑になる**。実績値では
  6066 呼び出し中 5673 失敗(**93.5%**)で、成功を含む run は 582 中 58 だけだった。
  つまり**「緑」は基本的にツリー一致の緑**で、視覚検証を含むとは限らない
- **エラーは入れ子。最上位だけ見ても何も分からない**。`LanguageModelError(-1)` は常に
  「The operation couldn't be completed.」で、真因は `NSMultipleUnderlyingErrors` の奥にある。
  `FMHealth.describe` が `←` 区切りで畳んで出すので、そちらを読む
- **2026-07-27 に観測した全滅の連鎖**(M2 Ultra / macOS 27 beta):

  ```
  FoundationModels.LanguageModelError(-1)
   ← com.apple.SensitiveContentAnalysisML(15)          sanitizeText 失敗
   ← CombinedTextSanitizerBackend.BackendError(1)
   ← ModelManagerServices.ModelManagerError(1001)      安全ガードレールのモデルがロードできない
  ```

  落ちているのは**本体の LLM ではなく安全ガードレール**(`com.apple.fm.language.instruct_300m.safety`)。
  ガードレールは**テキストのみの呼び出しでも必ず通る**ので、これが死ぬと画像添付の有無に関係なく
  **FM 機能が全滅**する。アセット記述子はディスク上に存在しており、欠落ではなくロード失敗
- **飽和(スループット不足)とは別物**。飽和なら成功が混じるが、この事象は**失敗率 100%** になる。
  結果 JSON の `fm.failures / fm.calls` で必ず区別すること
- **並列 run 中に発生しやすい**。modelmanagerd が `unloadIfNeededToMakeRoom` で
  安全モデルを積み降ろしし続けた直後に落ちた(実測: 14 ワーカーが一斉に occlusion-guard を叩いた
  E2E の途中で成功→全滅に転じ、以後プロセスを変えても回復しない)。ホスト RAM の枯渇ではない
  (192GB 中 57GB 空き)。**FM はホスト全体で直列化される**(performance-tuning §FM)ので、
  並列に投げてもスループットは増えず、この積み降ろしだけが増える
- **回復手段は現時点で「マシン再起動」しか確認できていない**(再起動直後は成功する。
  ただし数分〜十数分の並列実行で再発する)。`GenerativeExperiencesSafetyInferenceProvider` は
  root 権限のため一般ユーザーでは kill できない。ログでの確認:

  ```
  /usr/bin/log show --last 15m --style compact \
    --predicate 'eventMessage CONTAINS[c] "End sanitizeText"'
  ```

  (`log` は shell 関数に食われることがあるので**絶対パスで叩く**。自分の述語文字列が
  `log` プロセス自身のログに出て**偽の成功行**に見えるので、プロセス名まで確認すること)

## FM 呼び出しの直列化(FMLock)

FM は**ホスト全体で直列化される資源**(スループットは並列度によらず約1回/秒)。並列ワーカーから
同時に投げても速くならず、modelmanagerd のモデル積み降ろし(`unloadIfNeededToMakeRoom`)だけが
増える。そこで呼び出し側でも待ち行列を作る(`FMLock`。~/Library/Caches/ftester/fm.lock への flock)。

- **リポジトリ単位ではなくホスト単位**。別リポジトリの ftester とも直列化する
- **全ての FM 呼び出しがこのロックを通る**のが不変条件(occlusion / heal / screenIs / triage /
  ScenarioNamer / TestbaseDrafter)。新しい FM 呼び出しを足すときは必ず通すこと。
  監査は `grep -n "LanguageModelSession" Sources/FTAgent/*.swift`(FMDoctor は可用性判定なので対象外)
- **取れなければ FM をスキップする**(既定 20 秒)。全ワーカーが並ぶと最後尾の待ちが積み上がり
  シナリオの壁時計タイムアウトを超えうるため、この安全弁は外せない。スキップは**失敗とは別に
  数える**(`FMHealth.recordSkip`。失敗率の分母を汚さない)
- **A/B 計測の殺しスイッチ**: `FT_FM_SERIALIZE=0` で無効化(acquire が常に true = 素通り)

  ```bash
  FT_FM_SERIALIZE=0 Scripts/e2e.sh   # 直列化なし
  Scripts/e2e.sh                      # 直列化あり(既定)
  ```

- **A/B は1回の再起動では取れない**。片方の実行で FM を殺すと、もう片方が死んだ状態から
  始まってしまう(FM は一度落ちるとプロセスを変えても回復しない)。**アーム毎に再起動する**こと

### 検証結果(2026-07-27): **直列化では FM の全滅を防げない**

導入の動機だった「積み降ろしの連発 → 全滅」という因果は**反証された**。積み降ろしは全滅の
随伴現象であって原因ではない。アーム毎に再起動して全 SUT の E2E を回した実測:

| プロファイル(実行順) | 直列化 ON | 直列化 OFF |
|---|---|---|
| 1本目 | 21 calls / 0 失敗 | 21 calls / 0 失敗 |
| 2本目 | 9 calls / **9 失敗** | 21 calls / **21 失敗** |
| 3本目以降 | 全て 0% | 全て 0% |

**ロックは正しく効いていた**(空振りではない)ことを次で確認済み:
FM 呼び出しの時間的な重なりがゼロ(別プロセスが 1.5〜3 秒間隔で順番待ち)/
p50 レイテンシ 2416ms → 1675ms(−31%)/ ロック待ちによる skip は 0 件。

**崩壊のトリガーは時間でも並列度でもない**。再起動から E2E 開始まで 43 分あって FM は生きており
(時間ではない)、直列化で並列度を 1 に落としても崩壊した(並列度でもない)。両アームとも
**累積 20〜30 回の呼び出しで尽きる**ように見えるが、2 標本からの推測で確証はない。

直列化は**この目的では効果が無かった**が、実測で害が無く p50 が下がるため残している。
全滅そのものへの対策は**サーキットブレーカ**(下記)側で行う。

## サーキットブレーカ(FMBreaker)

FM は死んだら**再起動まで回復しない**ので、死んだ後も呼び続けるのは純粋な浪費
(実測: 全滅した 1554 シナリオで合計 31 分を捨てていた)。**連続 3 回失敗したら以後は呼ばない**。

- **入場は FMGate に一本化**している。`FMGate.enter()` が ①ブレーカ ②直列化ロック を順に見る。
  **新しい FM 呼び出しを足すときは必ずここを通す**(監査: `grep -c "FMGate.enter" Sources/FTAgent/*.swift`
  と `grep -n "LanguageModelSession" Sources/FTAgent/*.swift` の数を突き合わせる。FMDoctor は
  可用性判定なので対象外)
- **ホスト単位**(~/Library/Caches/ftester/fm-breaker.state の mtime)。全滅はホスト全体の事象で
  ワーカーはプロセスが別なので、プロセス内カウンタだけだと 14 ワーカー分を無駄打ちする
- **成功したら即座に復帰**する。10 分(cooldown)経過後は 1 回試させる(half-open)ので、
  FM が復活したことを検知できる
- ブレーカ由来のスキップは**失敗と別に数える**(失敗率の分母を汚さない)。実行後の警告に
  「N 件はスキップしました」として出る
- `FT_FM_BREAKER=0` で無効化(切り分け用)

**実測(2026-07-27・FM 全滅状態)**: 同一シナリオの FM 呼び出しが **11 回 → 3 回**へ。
浪費が 6.0 秒(3 回)で止まり、残り 8 回はスキップされた。

## デバイス供給の競合(モニターと run が同じデバイスを取り合う)

拡張のモニターは watchdog で `device-up` を投げる。run と同じデバイス群を使うので競合し得る。
**マシン再起動直後**(全デバイスが落ち、拡張も run も同時に供給を始める)が最も踏みやすい。

- **XCUITest ランナーは 1 デバイス 1 本が OS 制約**。2 本目は永久に announce せず、
  そのデバイスのシナリオが全滅する
- 供給側の防御は2段:
  1. `BridgeProvisioner.planBridge` が **announce 前のランナーも見て `.adopt`(起動せず待つ)**
     に落とす(検出は `BridgeLauncher.portsByUDID` = プロセス引数の `-destination id=<UDID>` 照合。
     `scanRunningBridges` は /status 応答済みしか映らないのでこれだけでは足りない)。
     引き取ったランナーが応答しなければ止めて同じポートで立て直す(親を失ったゾンビ対策)
  2. run は**供給フェーズ(install・凍結triage)の間も run-lease を保つ**(`SupplyLeaseHolder`)。
     `RunOrchestrator` の lease はシナリオ実行中しか書かれないため、その手前に watchdog の
     `device-up` が割り込む穴が空いていた
- それでも手で確実に避けたいときは `ftester.autoRepairBridge` を false にするか、
  E2E 前にモニターパネルを閉じる
- **`.adopt` は健全な環境では通らない**(announce 前のランナーが残っていないと発火しない)ので、
  E2E が緑でも「退行が無い」以上のことは言えない。実際の発火は再起動・拡張再起動を跨いだときに
  自然と起きる。**通らない経路を「E2E 緑」で検証済みと書かないこと**
- **Android エミュレータは run が自動起動しない**(iOS シミュレータは供給が起こす)。
  再起動後は `ftester devices up --project <名> --profile <名>` を先に回す

## macOS / Xcode ベータの整合

- macOS ベータを更新したら Xcode も同じベータへ揃えてフルリビルド。FoundationModels の ABI 不整合で
  全バイナリが dyld クラッシュする(swift build は SDKROOT/--sdk を無視するため Xcode 側を揃えるしかない)
- Xcode(beta)単体の更新でも同様: iOS ランタイム導入(`xcodebuild -downloadPlatform iOS`)+
  ランナー再ビルドで整合させる。不整合はアプリが数操作で「Application is not running」クラッシュする
  (`ftester doctor` が DTXcodeBuild 不一致を警告。2026-07-21 実害)

## テストが接続拒否(「ドライバへの接続が拒否されました」)で全滅したら

まず**プロファイル経路で走ったか**を確かめる。実行プロファイル未指定だと `--platform/--port` の
直接ポート接続に落ち、**ブリッジが自動供給されない**ため、事前に `bridge up` していなければ
全シナリオが即失敗する(拡張は 2026-07-26 から未指定で実行を止めるが、CLI では今も起こる)。

- **run.json の `machine` がホスト名なら非プロファイル経路**(プロファイル経由ならマシン
  プロファイル名が入る)。`scutil --get ComputerName` と比べれば一目で分かる
- **全シナリオが数十 ms・run 全体が数秒**なら供給が一度も走っていない(供給は数十秒かかる)
- 生きているブリッジは `curl -s 127.0.0.1:<port>/status` で確認する。`.ftester/bridge-<port>.log`
  や `bridge-<port>.inapp` は**残骸が残る**ので、ファイルの存在は稼働の証拠にならない。
  `/status` の `sessionBundleID` で「どのアプリのブリッジか」まで見ること(別 SUT のブリッジが
  生きていても対象アプリには使えない)

## ワーカーが「ブリッジ接続不能のため離脱しました」で落ちたら

**まず XCUITest ランナーのクラッシュを疑う**(2026-07-28 に真因確定・修正済み)。
`~/Library/Logs/DiagnosticReports/FTesterRunnerUITests-Runner-*.ips` が積まれていれば確定。
スタックが `Issue.record` → `Event.post` → `SwiftTestingInteropRecordHandler` の**再帰**で
数千段になっていれば、XCUI の操作失敗を起点にしたツールチェーン不具合(design.md
「XCUITest ランナーは『操作の失敗』でプロセスごと落ちる」)。

- **ホスト側の症状は2種**。`The request timed out` / `The network connection was lost`
  (ランナー死=処理中の HTTP が返らない)と、**離脱せずに「12 回スクロールしても見つかりません」**
  (別アプリを掴んで無言で空振り)。後者は失敗レポートの要素一覧が**対象アプリの画面のまま**なので
  「スワイプが効いていないだけ」に見える
- ランナー側の決め手は `.ftester/bridge-<xcuiPort>.log` の
  `Failed to application <bundleID> is not running`。**その bundleID が対象アプリと違えば**
  セッションの取り違え(使い回した XCUITest ブリッジが前のプロジェクトのアプリを指したまま)
- **再現条件は「複数 SUT を連続で回す」**。`Scripts/e2e.sh --ios --ios-inapp --cmp` のように
  SUT を1つに絞ると出ない(プロジェクトを跨いだセッション残留が起きないため)。
  切り分けは必ずフル構成で、**A/B は変更を `git stash` して同じ条件で並べる**
  (実測: ベースライン フル×2 = 各1件離脱、修正後 フル×2 = 0件)

## テストが「Application is not running」で全滅したら

ランナーや自分の変更を疑う前に **SUT のバックエンド死活を確認**する
(sut-ec-mobile は localhost:8090 の dev サーバ。停止中はアプリが非同期例外でクラッシュする)。
apps プロファイルの healthCheckURL が実行開始時に警告を出す。

バックエンド停止の症状は 2 種が混在する(実測 2026-07-27): SUT の SIGABRT クラッシュ
(未処理コルーチン例外。`~/Library/Logs/DiagnosticReports/` に .ips が積まれる)と、
エラー画面のまま要素が解決できない大量失敗。**決め手は失敗レポートの「失敗時点の要素一覧」**
(エラー画面 `#view_error`「読み込みに失敗しました」が写っていればバックエンド起因で確定)。
.ips が積まれていてもツールや OS beta を疑う前に `/health` を確認する。

## Android 凍結まわりの検証の罠

- **画面 OFF(KEYCODE_SLEEP)はフェイク凍結として万能ではない**: screencap は実凍結と同一の
  一様フレーム(<30KB)になるため **blank 検出・事前修復パスの検証には使える**(検出→sleep/wake
  修復→回復、が決定論的に再現する)。しかし **a11y 駆動(tap/type/textIs)は画面 OFF でも全て通る**
  (実測: シナリオ実行中に画面 OFF にしても 18/18 成功)ため、「シナリオ失敗→凍結判定→修復」の
  実行中経路は発火させられない。さらにシナリオの launch が画面を起こす過渡で別種の失敗が出る
  (注入アーティファクト。実凍結の症状ではない)。実行中修復パスの実発火はフェイクで強制できず、
  本番ログの「実行中の画面凍結を修復」で観測する
- **実凍結は事前修復が先に治すため「実行中だけ凍結」を意図的に作れない**(実凍結の誘発は
  8台並列 run の反復のみ。1台単独負荷・アイドルでは発生しない。performance-tuning.md §7)
- **凍結のホスト側証跡は `~/Library/Logs/ftester/emulator/<AVD>.log`**(DeviceBooter が
  emulator stdout/stderr を保存。ブート毎 truncate)。根因の Metal エラー
  (`GLDRendererMetal command buffer completion error` / `IOGPUCommandQueueErrorDomain 518`)は
  ここにしか出ない(2026-07-25 実測)。凍結個体を調べるときはまずこのログを見る
- **エミュレータ操作は既定で emulator gRPC(EmulatorController)経由**(スクショ/キー・タッチ注入/
  停止等。実機・gRPC 失敗個体は自動で adb フォールバック。`Sources/FTAndroid/EmulatorControl.swift`)。
  gRPC 起因を疑うときは **`FT_EMULATOR_CONTROL=adb`** で全面 adb に切り替えて比較できる
  (gRPC を話すのは Swift だけ。拡張の凍結修復も `ftester api repair-display` 経由でここを通るため、
  この環境変数1つで両方効く)。挙動差の切り分けはまずこれ。
  **iOS のシミュレータ列挙も同様に CoreSimulator 直叩きが既定**(design.md §16.4)で、
  **`FT_SIMULATOR_CONTROL=simctl`** が殺しスイッチ
- **run が遅くなったら負荷トリアージを先に**: ① `top` で qemu の空転(劣化個体はアイドルでも
  ~73%/台消費しホスト全体を遅くする)② run 同梱の `host-metrics.ndjson`(遅い run だけ CPU 飽和
  していれば環境要因)。Spotlight/mediaanalysisd のインデックスストームは CPU 数百%でも run を
  ほぼ遅くしない(M2 Ultra 実測)ので容疑から外してよい
- **guest reboot の完了判定は「1 でなくなる」→「1 になる」の2段で見る**: `adb reboot` 直後は
  まだ旧セッションが `sys.boot_completed=1` を返すため、いきなりブート待ちに入ると即成功して
  再判定が**凍結したままの旧画面**に当たる(run 前トリアージの実装 `ProfileWorkerFactory.rebootGuest`)。
  また再起動中は screencap 自体が失敗し、blank プローブは安全側の「非 blank」に倒れるので、
  **ブート完了を確認できない個体を blank 再判定に掛けてはいけない**(復帰と誤認する)
- **CPU 描画(swiftshader)フォールバックは emulator プロセスを再起動しないと戻らない**
  (`-gpu` は起動引数固定。ゲスト再起動・gRPC RESET では戻らない)。戻す経路はモニターの
  「GPUで再起動」「デバイスを全て起動」と、実行プロファイルの `recoverCpuFallbackToGpu`
  (design.md §11)。**例外**: Wipe Data の再ブートは `startEmulator` の既定 `-gpu host` で
  起き上がるため、しきい値超過の個体は副作用で GPU に戻る(意図した復帰機能ではない)
- **凍結調査は両経路スイープで**(`adb screencap` サイズと gRPC スクショの画素一様判定を並記)。
  readback 白化と host キャプチャ黒は独立に壊れるため片経路だけでは誤診する。シナリオ成功率は
  表示層の劣化を映さない(凍結9/14台でも 18/18 成功する)。変種一覧・スケール上限・Metal エラー
  指標の正本は performance-tuning.md §7

## 実機(kind: physical)の検証

プロファイルの書き方は design.md §11.2。ここは実機でだけ踏む罠だけを置く。

### Android 実機

- **画面ロックは「なし」にしておく**。PIN/パターンが設定されていると adb から解除できず、
  ロック中は `UiAutomation.getRootInActiveWindow()` が対象アプリにならないので **全シナリオが
  launch 500(「アプリの画面が表示されませんでした」)で落ちる**
- run 前に `AndroidPhysicalDevice.prepareForRun` が点灯・ロック解除・消灯抑止
  (`svc power stayon true`)を行う。`stayon usb` では**効かない**ことがある(AC として認識される
  ケーブル/ハブがあり、bitmask が USB=2 だけだと外れる。true=AC|USB|WIRELESS=7 を使う)
- **ロック状態の判定に `isKeyguardShowing` と `mCurrentFocus` を使ってはいけない**。
  Pixel 4a/Android 13 実測(2026-07-25)で、実際には解除されランチャーが見えている状態でも
  `true` / `NotificationShade` を返し続けた。**信用できるのは `topResumedActivity` の有無だけ**
  (ロック中はどのアクティビティも resume されないので行ごと消える)
- `wm dismiss-keyguard` は非同期で **解除完了まで実測 3〜7 秒**。待たずに launch すると
  run の初回シナリオだけが落ちる(8 run 中 1 件の flake として現れた)
- **画面凍結(blank-screen)判定は実機では動かない**。閾値(30KB)が 1080x2424 エミュレータ較正で、
  誤判定すると健全な実機に `adb reboot` を撃つため、事前トリアージ・事後プローブ・失敗時の
  blank 証跡判定のいずれからも実機を除外してある
- ブリッジ起動時のアニメーション無効化と `hidden_api_policy=1` は **実機では設定が永続する**
  (使い捨てのエミュレータと違う)。戻すときは端末の開発者オプションから
- 検証実績: Pixel 4a(Android 13 / arm64)で E2E-Android 全 21 シナリオ×6 連続グリーン
  (消灯状態からの復帰込み。2026-07-25)

### iOS 実機

- **署名が要る**。`~/.config/ftester/config.json` の `developmentTeam`(または環境変数
  `FT_DEVELOPMENT_TEAM`)に Apple Developer の Team ID を入れる。bundle id プレフィックスは
  `bundleIDPrefix` / `FT_BUNDLE_ID_PREFIX`(既定 `com.example` のままだと他チームが登録済みの
  App ID と衝突しうる)。ビルドは `-allowProvisioningUpdates` 付きで走る
- **Team ID は証明書の OU**。`security find-identity -v -p codesigning` の
  `Apple Development: <you> (XXXXXXXXXX)` の**括弧内は証明書 ID であって Team ID ではない**
  (取り違えると `No Account for Team "..."` で落ちる。2026-07-25 に実際に踏んだ)。正しくは:
  ```
  security find-certificate -c "Apple Development: <you>" -p | openssl x509 -noout -subject
  # → subject= UID=..., CN=Apple Development: ... (証明書ID), OU=GF42S2868Q, ...  ← OU が Team ID
  ```
- 端末側は「このコンピュータを信頼」と **Developer Mode の有効化**が前提。
  `xcrun devicectl list devices` に出ることを先に確認する
- **端末のロックを解除しておく**(Android と同じ前提)。ロックされていると xcodebuild が
  `Unlock <name> to Continue` で無言のまま止まる。テスト中に再ロックされないよう
  **設定 → 画面表示と明るさ → 自動ロック を「なし」**にしておくこと。この条件は
  「失敗」ではなく「進まない」だけなので、検出しても throw せず待ちながら 1 回だけ促す
  (`IOSDeviceTransport.blockingCondition`)
- **端末で開発者証明書の信頼が要る**。ビルドとインストールが成功しても、起動時に
  `The application could not be launched because the Developer App Certificate is not trusted.`
  で落ちる。iPhone の **設定 → 一般 → VPN とデバイス管理** からデベロッパ App の証明書を「信頼」する。
  **「初回だけ」ではない**: 証明書やプロビジョニングプロファイルが作り直されると再度必要になる
  (2026-07-26 に一度信頼済みの端末で再発)
- **端末が起動を拒否した条件は xcodebuild の終端マーカーを待ってはいけない**。証明書未信頼の
  エラーはログの 20 秒時点に出ていたのに、`** TEST EXECUTE FAILED **` も `Testing failed:` も
  最後まで出ず、締切 181 秒まで待たされたうえ「LAN アドレスを取得できません」という無関係な
  理由で失敗した(2026-07-26 実測)。証明書未信頼・Developer Mode 無効は単独で終端扱いにする
  (`IOSDeviceTransport.runnerFailureReason`)。理由を特定できない失敗だけは誤検知を避けるため
  従来どおりマーカー待ち
- `devicectl list devices` の **Identifier 列(UUID)と `hardwareProperties.udid`(`00008130-...`)は
  別物**。`xcodebuild -destination id=` が受け付けるのは後者だけ(`devicectl --device` はどちらでも
  通る)。プロファイルの `udid` には後者を書く(前者を書いても解決はする)
- **`connection.state` は当てにならない**: USB 接続中で `devicectl list devices` が
  `available (paired)` と表示している実機でも `disconnected` のままだった。未接続の実機は
  そもそも一覧に出てこないので、一覧に居ること自体を到達性の主信号にしている
- `hardware.reality`(CoreDevice の `DeviceReality`)は **`physical` / `simulated` / `virtual`(VM)
  の三値**だが、**実機は値を出さずキーごと省略する**(Xcode 27 beta 4 実測: 68 台中 67 台が
  `simulated`、実機 1 台はキー欠落)。`"physical"` 一致で拾うと**実機が 1 台も見えない**ので、
  必ず「`simulated` 以外」で弾くこと
- SUT の実機ビルド例: `E2EAppIOS/scripts/build-ios-device.sh`(`-sdk iphoneos` + 自動署名 →
  `dist/ios-device/`)。シミュレータ版(`dist/ios-simulator/`)とは実体が別なので
  **apps プロファイルを分ける**(`ft_e2e_ios_device.json` / 実行は `ios-device`)
- **xcodebuild のテストログは CRLF**。Swift では `"\r\n"` が 1 つの Character なので
  `split(separator: "\n")` は CRLF を**一切分割しない**(ログ全体が 1 行になる)。
  ランナーの `FT_BRIDGE_ADDR` 宣言を拾う所で踏んで 180 秒待って失敗した。
  ログを行単位で見るコードは `split(whereSeparator: \.isNewline)` を使うこと
- ブリッジの到達手段の確立に失敗したら**必ず `launcher.stop()` する**。xcodebuild は実機で
  走り続けるので、止めないと失敗のたびに常駐ランナーが端末に溜まる(実測で 5 本残った)
- **実機とシミュレータを同じ run に混ぜられる**が、xctestrun は種別ごとに別物なので
  `prepareSharedBuilds` は**種別ごとに build-for-testing する**(1 つだけビルドすると、
  選ばれなかった側が `xctestrunNotFound` で落ちる)
- 検証実績: iPhone 15 Pro(iOS 26.5.2)で E2E-iOS 全 20 シナリオ = LAN ×3・USB ×6 連続グリーン
  (2026-07-25〜26)。ブリッジ供給は約 8 秒。壁時計は USB 181〜211s / LAN 241〜259s
- **トランスポートは端末の接続形態で決まる**: `devicectl` の `transportType` が `wired` でなければ
  (= WiFi のみ)**iproxy は USB トンネルを張れない**ので lan に落ちる。ここを見ずに
  「iproxy があれば usb」で選ぶと、`network connection was lost` で 180 秒待って失敗するだけの
  無情報な結果になる(2026-07-25 に実際に踏んだ)。明示指定 `FT_IOS_DEVICE_TRANSPORT` は尊重する
- **端末ロックの検出は締切後にもう一度ログを読む**。xcodebuild は諦めた時点で初めて
  `Unlock <name> to Continue`(deviceprep Code=-3)を書くことがあり、待機ループ内の読み取りだけでは
  間に合わずタイムアウトとしか出ない(`BridgeLauncher.waitUntilReady` の physicalDiagnosis)
- **ブリッジのトランスポートが 2 択**(デバイス内のループバックはホストから見えない。
  Xcode 27 の devicectl にポート転送は無い)。`FT_IOS_DEVICE_TRANSPORT=lan|usb` で明示、
  未指定なら iproxy があれば usb、無ければ lan。**usb を強く推奨**(下記実測):

  | 経路 | 1 往復(`/status`) | ばらつき | E2E-iOS 20 本 |
  |---|---|---|---|
  | シミュレータ(loopback) | 1.1 ms | σ 0.2 | 174.6s(6 台並列で壁 38.5s) |
  | 実機 **usb**(iproxy) | **4.7 ms** | σ 0.7 | **181.3s** |
  | 実機 lan(WiFi) | 47.9 ms | σ 26.9 | 241.1s |

  LAN が遅いのは **iOS の WiFi 省電力**(ICMP でも avg 74ms / σ 32ms)。DSL の 1 ステップは
  セレクタ解決・操作・整定確認で 8〜13 回ブリッジを往復するため、48ms × 10 回 ≈ +0.5s/ステップに
  なる。ペイロードは 0.1KB なので**帯域ではなく往復回数**の問題(2026-07-25 実測)。
  usb にすると 1 シナリオあたり 12.1s → 9.1s で、シミュレータ(8.7s)とほぼ同等になる:
  - `lan` … ランナーが `0.0.0.0` に bind し(`FT_BIND_ALL=1` を xctestrun に注入)、自分の
    LAN IPv4 を `FT_BRIDGE_ADDR=<ip>:<port>` としてテストログ(`.ftester/bridge-<port>.log`)に
    1 行出す。ホストはそれを読んで宛先にする。**Mac と端末が同じネットワークに居ること**
    (クライアント分離 WiFi では不可)
  - `usb` … `iproxy`(`brew install libimobiledevice`)で USB トンネルを張り 127.0.0.1 を維持する
- 実機とシミュレータで DerivedData を分けてある(`.ftester/DerivedData-device`)。混在させると
  `findXCTestRun` が iphoneos/iphonesimulator の誤った方を掴む
- **engine=xcuitest なら実機で動く、は誤り**だった箇所: `FastLaunchDriver`(xcuitest でも既定 ON・
  中身は `simctl terminate`+`launch`)と `LaunchPreflightDriver`(`simctl get_app_container`)は
  実機では無効化される(`--physical`)。素の `XCUIApplication.launch()` 経路に落ちる
- アプリは `xcrun devicectl device install app` で入る(**署名済みの .app/.ipa が要る**)。
  SUT のシミュレータ用ビルド(`-sdk iphonesimulator`)はそのままでは使えない
- **UDID の先頭は機種共通**(`00008130-` は iPhone 15 Pro 系の固定値)。先頭 8 文字を
  識別子として表示すると同型機が全部同じ表示になる。個体固有なのはハイフン以降

### iOS 実機ブリッジが立たないとき(3 大原因)

原因はほぼこの 3 つ。**いずれも現在は原因が名指しで報告される**ので、まずメッセージを読む
(そうなるまでに 3 回とも「180 秒待って無情報なタイムアウト」を踏んでいる)。
ログは `.ftester/bridge-<port>.log`:

| 症状・ログ | 原因 | 対処 |
|---|---|---|
| `Unlock <name> to Continue`(deviceprep Code=-3) | 端末ロック | 解除+自動ロック「なし」 |
| `Developer App Certificate is not trusted` | 証明書未信頼 | 設定 → 一般 → VPN とデバイス管理 |
| `network connection was lost` が延々続く | WiFi 接続なのに usb を選んだ | USB で繋ぐ(自動で lan に落ちる) |

検出側の設計上の要点(**同じ間違いを繰り返さないため**):
- ロックは「失敗」ではなく「進まない」だけなので throw せず促す。ただし xcodebuild は
  **諦めた時点で初めて**理由を書くことがあるので、待機ループ内だけでなく**締切後にもう一度**
  ログを読む(`BridgeLauncher.waitUntilReady` の physicalDiagnosis)
- 証明書未信頼・Developer Mode 無効は**終端マーカーを待たずに確定**させる(理由を特定できない
  失敗だけマーカー待ち)。詳細は上の「iOS 実機」節
- トランスポートは `transportType` で決める。`FT_IOS_DEVICE_TRANSPORT` の明示指定は尊重する

### 実機とモニター・API

- `api list-devices` / `api monitor` は実機を返す。**状態判定は両者で共有**(`determineStates`)なので、
  片方を直せば両方直る。実機で踏んだ罠:
  - **Android 実機は `avd` が無いので、AVD 前提のままだと永久に offline**(「avd が未設定です」)。
    `serial` を `adb devices` の接続一覧で確認する分岐が要る
  - **iOS 実機の `/status` は device に機種名("iPhone")を返す**。マシンプロファイルのデバイス名
    (例「iPhone wave(実機)」)と一致しないため、名前照合では永久に connected にならない。
    ランナープロセスの `-destination id=<UDID>` で帰属を決める(`BridgeLauncher.portsMatching`)
  - LAN 経由の実機ブリッジは 127.0.0.1 に居ないので、ポートスキャンは `.endpoint` を見る
  - **`ps -p <pid列>` を使ってはいけない**: 範囲外の pid が 1 つ混じるとエラーになり、
    **生きている分も含めて出力が空になる**(pid ファイルは壊れた値を持ち得る)。全プロセスを
    列挙して pid で引く。また monitor は 2 秒間隔でこれを呼ぶので、pid ごとに `ps` を spawn すると
    常駐ブリッジ本数 × 0.5 回/秒のプロセス生成になる(1 回にまとめる)
- `api installed-devices` は `ios.physicalDevices` / `android.physicalDevices` に接続中の実機を返す
  (既存の `devices` / `avds` はシミュレータ・AVD のまま。追加フィールド=後方互換)。
  AVD には `model`(config.ini の `hw.device.name`)と `os`(`image.sysdir.1` の `android-<API>`
  から導出)も付く — エミュレータはプロファイルに機種/OS を持たないため、表示はここが唯一の出所
- `kind`("virtual"/"physical")を `list-devices` と `monitor` の各デバイスに追加した。
  拡張側は欠落を "virtual" に正規化する(旧 CLI 互換)

### 実機と VSCode 拡張

- マシンプロファイル編集フォームは実機で表示が変わる: iOS は機種/OS 行を隠し **udid** を、
  Android は AVD 行の代わりに **serial** を readonly 表示する(いずれも実体を指すので変更不可)。
  実機で識別子を空にした保存は拒否する(`updateDeviceInMachineProfile`)
- デバイスタイルは実機に「実機」バッジを出す。右クリックの起動/停止は**項目を残したまま
  ラベルを「ブリッジを起動/停止」に変える**(実機は端末そのものを起動・停止せず、操作対象は
  ブリッジだけ)。**項目を隠してはいけない**: 隠すとモニターから実機のブリッジを起動できず、
  タイルが「接続中」のまま何もできなくなる(2026-07-25 に実際にそうしてしまった)
- `kind`/`serial` は拡張側の 2 箇所(`config.ts` の `MachineDeviceEntry` と `monitorModel.ts` の
  同名型)に独立定義がある。**両方直すこと**(vscode 非依存を保つための意図的な重複)
- webview→拡張の `machineDeviceUpdate.fields` に `serial` を足した。**拡張と webview のバンドルは
  別々に更新されうる**ので、受信側は欠落を "" に補う(旧 webview と混ぜても壊さない)
- 機種/OS はプロファイルに無ければ `installedDevicesRequest` で取りに行くが、**要求は
  1 デバイス 1 回に絞ること**。この要求は毎回 `ftester api installed-devices` を spawn する
  (devicectl + adb getprop で数秒)ので、値が埋まらないデバイス(未接続の実機・`hw.device.name`
  の無い AVD)では 応答→再描画→再要求 が閉じず CLI を叩き続ける(2026-07-25 のレビューで検出)
- **ネイティブ `title` は表示遅延を指定できない**(ブラウザ/OS 固定で約 1 秒)。省略表示の全文を
  素早く出したい所は自前ツールチップ(`hoverTip.js`、0.2 秒)を使う。要点は
  ① `position: fixed` で body 直下に出す(名前ピルの親 `.tile-header`/`.lane-header` は
  `overflow: hidden` なので子要素方式だと切られる)② 対象に `title=""` を置いて祖先の `title` が
  遅れて二重に出るのを止める

### 実機の画面配信(ftester-devicepoll)

**実機は両OSとも `ftester-devicepoll`**(スクリーンショットのポーリング → MJPEG)に一本化した。
既存の 2 ヘルパーが実機で使えないため:

- `ftester-simstream` は CoreSimulator/SimulatorKit の私有 API で deviceSet から UDID を引くので
  **iOS 実機では原理的に不可**。macOS 27 では iOS 実機を AVCaptureDevice として出す
  **DAL プラグインも消えている**(`/System/Library/CoreMediaIO/Plug-Ins/DAL` が存在せず、
  カメラ権限を付与した Info.plist 埋め込みバイナリでも CoreMediaIO デバイス数 0。2026-07-25 実測)
  ので、QuickTime 方式の代替も無い
- `ftester-androidstream`(adb screenrecord)は Android 実機だと **画面が動いている間しか
  フレームが流れない**(操作中 455KB / 静止画面はキープアライブの 20 バイトのみ)。
  エミュレータは静止時もフレームが出るためこの差は顕在化しない
- あわせて **`screenrecord --time-limit 0`(無制限)は API 34 以上でしか使えない**ことも判明
  (Android 13 実機は即終了して 47 バイト)。androidstream は API レベルで `0` / `180` を選ぶ

devicepoll の要点:
- 宛先は iOS が `--host/--port`(ブリッジの `/screenshot`)、Android が `--serial/--adb`
  (`exec-out screencap -p`)。拡張は `api monitor` の `kind`/`host`/`port`/`serial` で振り分ける
- 出力は **v1(MJPEG)固定**。`--max-width` は既存ヘルパーと同じく**幅**の上限
  (ImageIO の `kCGImageSourceThumbnailMaxPixelSize` は**長辺**基準なので長辺換算して渡すこと。
  そのまま渡すと 1080x2340 で 360 指定 → 166x360 になる)
- 実測(2026-07-25、fps=2 / max-width 360): Android 実機 360x780 が 7 秒で 13 枚、
  iOS 実機 360x781 が 8 秒で 16 枚。**静止画面でも出る**のがこの方式の要点

## 常駐ブリッジのセッション(iOS xcuitest を CLI で直接叩くとき)

`bridge up` で立てた常駐ランナーへ curl 等で直接 `/snapshot`・`/tap` すると、最初の1回が
`409`(セッション無し)で返ることがある。ランナーはアプリ参照(`sessionBundleID`)を `/session`
で初めて確立するため。**先に `POST /session` を投げる**こと(Runner/FTesterRunnerUITests/BridgeRouter.swift)。

- `simctl launch` で既に起動済みのアプリへ後付けで繋ぐ場合は `{"bundleID":"...","attachOnly":true}`。
  attachOnly は activate/launch せず前面到達だけ確認する(前面に無ければ即エラー)。通常 run は
  driver が自動で `/session` を張るのでこの手順は不要=CLI 直叩き時だけの話。
- **`/status` の `sessionBundleID` は次の `/session` まで残る in-memory 値**。対象アプリを
  アンインストールしても消えないため、削除済みアプリの死んだ参照が見えることがある(無害。
  次の `/session` で上書きされる)。`/status` の session 欄=「今アタッチ可能」の保証ではない。

## 録画(record:true)の検証

録画パイプライン(Recorder/Finalizer/Coordinator/`RecordingWallClock`)を触ったら、
ユニットテストでは AVFoundation・デバイス境界を捕まえられないため、record:true の実 run で確認する:

- **録画パイプラインの退行は `Scripts/e2e.sh --record` で検知できる**(各プロファイルの一時コピーに
  record:true を付けて実行し、`Scripts/check-recordings.py` が schemaVersion・クリップ数・
  クリップ長・mp4 存在を機械チェックする。元のプロファイルは書き換えない)
- **クリップ数 = シナリオ数**(シナリオが来なかったアイドルワーカーの録画は破棄される)、
  **クリップ長 ≒ シナリオ durationMs**(ミリ秒オーダーで一致するのが正常)、index.json(schemaVersion 2)の整合
- **VFR の罠**: simctl/screenrecord は「画面が変化した時だけ」フレームを吐く。切り出しは
  「区間開始前の最後のフレームを retime して先頭に置く」+「endSession で区間終了まで保持」が無いと
  先頭/末尾が欠ける(実測: 11.1s ソースが endSession 無しで 8.7s に縮んだ)
- **codec は H.264 固定**(再生側 = 拡張 webview の Chromium は HEVC 不可)。simctl に bitrate ノブは
  無く、圧縮はファイナライズの再エンコードで行う(bitrate は run profile の recordBitrateKbps、
  解像度は recordFullResolution。`VideoRecordingFinalizer` の shrinkThreshold を誤ると Android
  ソースの二重縮小になる実害があった)
- **サイズの目安**: 1テスト 0.1〜3MB(iOS 約50〜150KB/s、Android は静止的で約8〜30KB/s)。
  大きく外れたら解像度判定(shrinkThreshold)かビットレートを疑う
- Android screenrecord は180秒上限のセグメントループ。停止は**デバイス側プロセスへ kill -2**
  (ホストの adb クライアント kill ではファイルが壊れる)。iOS simctl は SIGINT 停止・SIGKILL 禁止
- **ホストの HW エンコーダ(AVE)無応答でファイナライズがハングし得る**(実害 2026-07-27:
  macOS 27 beta で 5 並列エクスポート+モニターの simstream 5 本の負荷中、`finishWriting` →
  `VTCompressionSessionInvalidate` → RemoteVideoEncoder の同期 XPC が AVE 応答待ちのまま止まり、
  全シナリオ成功後に run が終わらなかった)。保護は VideoRecordingCoordinator に実装済み:
  クリップ 1 本ごとに期限 `max(60s, ソース総尺)`・1 本でも期限超過したらその run の残りクリップを
  断念(警告 1 回)・エクスポート同時実行は 2 本。期限側は敗者 task を放置する
  (`cancelWriting` は固着した VT セッションのロックで共倒れし得るため呼ばない)
- **「全シナリオ完了済みなのに run が終わらない」の診断**: `sample <ftester の pid>` を取り、
  `VTCompressionSessionInvalidate` / `RemoteVideoEncoder_EncodeFrame` が居れば上記のエンコーダ
  無応答(相手側の VTEncoderXPCService プロセスも `AVE_UCRecv` で待っている)。ツールは期限で
  自力離脱するので待てばよい。頻発するなら OS 再起動でしか AVE は復旧しない

### WebView を触ったときの検証

- **`--ios-inapp` を必ず回す**。利用者の既定エンジンは hybrid = in-app 優先で、WebView の中身は
  in-app だけ **DOM 経路**(`InAppWebViewDOM`)を通る。既定の e2e.sh は iOS を xcuitest でしか
  回さないため、この経路が丸ごと未検証のまま緑になる。
- **SUT を絞らない**。WebView の埋め込み方がフレームワークごとに違い、退行が SUT を跨がないと出ない:
  ネイティブ(WKWebView 直)/ CMP(UIKitView interop)/ Flutter(platform view)。
  実例: CMP と Flutter は interop が合成タッチと `insertText` を横取りするため DOM 経路を使わない
  (uikit ホストのみ有効)。この分岐は E2E でしか壊れているとわからない。
- **効果測定は `FT_WEBVIEW_DOM=off` との A/B** で取る。比較は
  `Projects/E2E-iOS/results/runs/<run>/scenarios/WebViewの中身を操作できること.S0010.json` の
  `timeline`(scene 2 以降の exist/textIs の中央値)と `scenes[0].durationMs`。
- **ブリッジ版を上げ忘れない**。iOS = `bridgeProtocolVersion`、Android = `VERSION_CODE` +
  `expectedBridgeVersionCode`。上げないと稼働中の旧ブリッジが再利用され、**変更が入っていないのに緑**になる。
  開発中に同じ版のまま APK/dylib を差し替えるときは、明示的に `adb uninstall com.example.ftbridge` /
  アプリ再注入で入れ直すこと(実際に1度踏んだ)。検出の仕組みは下記。

## ブリッジ版数の上げ忘れ検出(2026-07-30)

`BridgeContractTests` が2段で検出する。実装を変えたらここが落ちるので、**版を上げてから**期待値を
貼り替える(貼り付け用のリテラルは失敗メッセージが出力する)。

| 段 | 何を見る | 捕まえる事故 |
|---|---|---|
| ルート表 | ハンドラの `case ("GET", "/status")` 等を正規表現で抽出 | エンドポイントの増減 |
| ソース指紋 | `BridgeSourceSet` が挙げる入力の内容 SHA256(ファイル単位) | **ルートが同じでハンドラだけ変えた**・入力ファイルの追加/削除 |

- **入力ファイルの一覧は `Sources/FTCore/BridgeSourceSet.swift` が唯一の定義元**。
  `InAppLauncher` の dylib 再ビルド判定も同じ一覧を使う(再掲するとズレる。実害: 共有 DTO の
  `WebViewDOMSnapshot.swift` が `build.sh` の入力なのに再ビルド判定から漏れ、そのファイルだけを
  編集しても古い dylib が注入され続ける状態だった)
- **指紋は生バイト = コメント編集でも落ちる**(意図的)。文字列リテラル中の `//` を素朴に削る
  コメント除去は**変更を見逃す側**に倒れるため、誤検出の側を選んでいる。版を上げるに値しない
  変更なら期待値の貼り替えだけでよい
- `AndroidRunner/build.sh` は `VERSION_CODE=` 行だけマスクしてハッシュする。マスクしないと
  「版を上げた」こと自体で指紋が動き、「ソースが変わった」信号が濁る
- **残る限界: 版を上げること自体は強制できない**。期待値を更新して版を据え置くことは手続き上
  できてしまう。リポジトリ内の期待値は書き換え可能なので原理的にここが上限で、達成しているのは
  「無音で緑」を「版数の判断を意識的に迫られる」へ変えることまで
- **反復開発中は「同じ版・別バイナリ」も再利用される**(2026-08-01 実害)。版を先に上げてから
  実装を差し替えていく開発ループでは、途中のビルドも最終ビルドも同じ版数なので、provision の
  版一致再利用が**古い方の稼働中ランナー**を掴む。計測・e2e の前に該当ブリッジを
  `bridge down` してから張り直すこと(版の照合では検出できない)
- **計測ハーネスは対象の版を開始時と終了時の両方で読む**(2026-08-01 実害)。計測中にランナーが
  死ぬとモニターが respawn するが、**張り直すのは別クローン・別ビルドのことがある**
  (どの clone の監視が先に気付くか次第)。開始時の /status だけ見て「v29 を測った」と
  思い込むと、途中から旧版を測っていても気付けない。終了時にも読んで食い違いを申告させる

### 保留: ブリッジ自身にソース指紋を申告させる案(再発明防止)

版数を人間が上げる代わりに、**ブリッジがビルド時に自分のソース指紋を埋め込み `/status` で申告し、
ホストは自分が計算した指紋と一致するものだけ再利用する**——これなら上げ忘れという概念自体が消える。
**Android で詰むため未着手**: コミット済み `AndroidRunner/prebuilt/ftbridge.apk` があるので、
`.java` へのコメント1行の編集でも受け手側のホストが「指紋不一致」で再インストールを試み続ける
(APK が古いままなので永久に一致しない = `AndroidBridgeVersionSyncTests` が警告している状態に
全編集で入る)。全編集で APK の作り直し・コミットが必須になる。

**再検討条件**: Android ブリッジの APK をコミット済み成果物ではなく供給時ビルドに変えられたとき、
または指紋の対象を「ソース」ではなく「ビルド成果物(dex)」に取れる安価な手段ができたとき。
