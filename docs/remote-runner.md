# リモートランナー構想(設計案・未実装)

2026-07-30 の検討結果の文書化。**実装は未着手**。着手判断は Phase 0(素振り・検証)の
結果を見てユーザーが行う。

## 1. 前提と目的

- **マシンは Mac に統一**(ユーザー決定 2026-07-30。クライアント・実行側とも)。
  非 Mac クライアントからの実行という要件は存在しない
- CI は self-hosted Jenkins / EC2 Mac([ci.md](ci.md))。**ジョブ粒度のリモート実行は
  CI が既に担っている**ため、本構想の固有価値は CI を経由しない対話的用途に限られる:
  1. **Mac フリートへのシナリオ並列分散**(夜間回帰のスループット。FM はホスト全体で
     直列化 ≈1回/秒 のため、screenIs 多用スイートは台数分の実質短縮になる)
  2. **デバイス/実機ラボの共有**(iOS 実機は元々 LAN/iproxy の2択で相性は悪くない)
- 着手判断の鍵は**上記需要が実在するか**。Phase 0 で確かめてから実装に進む

## 2. 却下済みの代替案(再提案しない)

| 案 | 内容 | 却下理由 |
|---|---|---|
| A. ブリッジ層で切る | `BridgeClient` の HTTP を遠隔ホストへ向ける | ステップ毎 snapshot の chatty なプロトコルに LAN RTT が乗り、ms 級チューニング(stale-guard 350ms・LPT 等)が崩れる。プロビジョニング(ブート・ランナービルド・インストール・ゾンビ掃除・凍結復旧)は全部ローカルプロセス制御前提で、遠隔化には常駐エージェント=第二プロダクトが要る |
| B. 独自プロトコルの常駐デーモン | ftesterd を立ててクライアントが接続 | 全マシン Mac なのでどのマシンもフルスタックが動き、役割分離の動機が無い。ジョブ粒度なら Jenkins の再発明。認証/TLS の自前実装が必要 |
| FM 分離構成 | デバイスは VM ファーム・FM は手元物理 Mac(案A の副産物) | 全 Mac(物理)前提で動機消滅 |

## 3. 採用方針: ジョブ(run)単位の SSH ディスパッチ

**対等ピアモデル**。どの Mac も clone + `Scripts/install.sh` で同一状態になれるので、
リモート実行=「向こうの Mac で普通にローカル実行し、結果を手元へストリームする」だけにする。
新プロトコル・認証・常駐デーモンは作らない(トランスポートは SSH)。

`ftester run --host <mac>` の流れ:

1. 適合チェック(§7。不一致は fail fast)
2. 転送(rsync: シナリオ・プロファイル・アプリバイナリ。アプリはハッシュでキャッシュ)。
   **リモートは外部構成(WORK_DIR 分離)前提・rsync 先はリモートの WORK_DIR**。
   クローン内に置くと install.sh の外部構成自動破棄(`reset --hard` + `clean -fd`)で
   次回実行時に消える
3. リモートで `install.sh`(冪等)→ 実行。転送後はリモートで scenario ターゲットの
   swift build が走る(コールドは数分。`clean -fd` に `-x` を付けない= .build 温存の
   既存設計が増分ビルドを効かせる)
4. **ストリームバックの実体は用途で分ける**: CLI/CI は `ftester run --quiet --junit` の
   出力中継、拡張(レーン表示)連携は `ftester api run` の NDJSON 中継
   (`ftester run` は人間向け出力で NDJSON を喋らない。ApiRunCommand が唯一の機械可読契約)
5. 成果物回収(reports/・JUnit・results DB・録画)。**JUnit 内 `report:` 行は
   リモートの絶対パス**なので回収後のローカルパスへ書き換える

## 4. 全体アーキテクチャ

```
┌─ ローカル Mac(発行側)────────────────────────────┐
│ ftester run --host mac2 --profile …                │
│  ├─ 適合チェック(rev / Toolchain / Protocol)     │
│  ├─ 転送(rsync: シナリオ・プロファイル・アプリ)  │
│  ├─ NDJSON 受信 → 進捗表示・拡張へ中継            │
│  └─ 成果物回収(reports/ ・junit.xml・results DB) │
└───────────────┬────────────────────────────────────┘
                │ SSH
┌───────────────▼─ リモート Mac(実行側)────────────┐
│ Background セッション(sshd 側)= control plane    │
│  └─ ジョブを session agent へ引き渡すだけ          │
│ Aqua セッション(自動ログイン+LaunchAgent)        │
│  └─ session agent が ftester run を spawn           │
│      = execution plane(シミュレータ・XCUITest・FM)│
└────────────────────────────────────────────────────┘
```

## 5. control plane / execution plane 分離(GUI セッション制約への回答)

GUI 依存は ftester のコードではなく **macOS のセッション意味論**に由来する
(launchd のセッション種別が Background[SSH 直・LaunchDaemon]か Aqua かで
WindowServer・ユーザー空間サービスへのアクセスが変わる。Linux の Xvfb に相当する
「ログインなしで Aqua を作る」公式手段は macOS に無い)。よってコード分離では消せず、
**Aqua に置くものを最小化する**のが唯一の現実解。

| コンポーネント | Aqua 必須? | 備考 |
|---|---|---|
| iOS シミュレータ + XCUITest | 実質必須 | レンダリング・スクリーンショット・XCUITest が Background で不安定(既知問題)。本ツールはスナップショット・録画多用で回避不能 |
| FM(FTAgent) | おそらく必要(未検証) | Apple Intelligence のデーモン群はユーザーセッション側。§9 で実測 |
| Android エミュレータ | 不要にできる可能性 | `-no-window` + swiftshader が定番。ただし §6 の検証が条件 |
| コンパイル・オーケストレーション・results・update | 不要 | 純粋にプロセスとファイル |

- **execution plane = session agent(LaunchAgent)**。責務は「ジョブを受けて
  `ftester run` を spawn し出力を中継する」だけに限定する。判断・プロビジョニングは
  ftester 本体に残す(CLAUDE.md「機械作業はスクリプト/CLI へ」と同じ方針)。
  加えて**ジョブは直列化(1本ずつ)** — 同一リモートへの同時ディスパッチは
  デバイス割当が競合する(単一マシンには無かった失敗モード)。並行受付は
  Phase 3 の分散スケジューリング側の課題として送る
- **運用前提: 自動ログイン有効 + スクリーンロック/スリープ無効 + LaunchAgent 自動起動**。
  再起動しても人手なしで Aqua が立ち、待ち受けに戻る。Jenkins の Mac agent
  (ログイン項目/LaunchAgent 起動)や EC2 Mac の CI 運用と同型で、
  **CI 前提を採った時点でどのみち必要になる運用**。追加負担は増えない
- 自動ログイン+ロック無効は物理アクセスに無防備。ラボ機/EC2 では通例許容されるが、
  導入時に方針として明示する
- 即席経路(素振り用・**検証対象の仮説**): SSH から `launchctl asuser <uid>` で
  コンソールユーザーのセッションへ注入。ただし asuser は Mach bootstrap 名前空間の
  切替だけで **WindowServer への完全なアクセスは保証されない**(GUI 系がこれだけでは
  動かない事例は既知)。成立可否は §9 の検証項目。不成立時の代替は
  `launchctl bootstrap gui/<uid>` 経由、またはスプール監視型 LaunchAgent
  (= Phase 2 の session agent が Phase 1 に繰り上がる)

## 6. Android ヘッドレスレーン(条件付き)

ios を含まず FM も使わないジョブは、Aqua 不要のまま(SSH 直で)実行できる可能性がある。
ディスパッチ時にジョブ要求(対象 OS・FM 使用)を見て Aqua 行き/ヘッドレス行きを振り分ける。

採用条件(どちらも実測必須):

1. `-no-window` での凍結挙動 — 既知の凍結トリガ「複数台同時描画」と sleep/wake 修復の
   知見は**窓あり前提**。ヘッドレスで消えるのか別の顔で出るのかを対照実験で確認
2. gRPC 制御の互換(特に KEY_WAKEUP 系の挙動)

## 7. 版整合・更新

- リモート側も clone + ソースビルド(配布方針どおり)。更新は `Scripts/update.sh` の
  仕組みにそのまま乗せる
- ディスパッチ前の適合チェックで **git revision・ToolchainFingerprint(Xcode/macOS)・
  ProtocolVersion** を照合し、不一致は**黙って走らせず fail fast**(このリポジトリの
  「片方だけ変えない」規律をマシン間に広げると、スキューは恒常的なバグ族になるため
  入口で遮断する)
- **rev 一致の意味 = 両者が同一 upstream コミットにいること**。ローカルの未コミットの
  ツール変更はリモートに載らない(ツール開発中の変更をリモートで試す用途はスコープ外)
- ProtocolVersion は「**ローカルの拡張 ↔ リモートの CLI**」という新しい版ペアにも適用
  される(§3 の `api run` NDJSON 中継時。既存の起動時照合をホスト単位に拡張)
- リモートの **TOOL_ROOT 解決は既存4箇所の規則を再利用**する(preflight.sh / update.sh /
  toolRootResolve.ts / Package.swift 宣言。`toolRootContract.test.mjs` の対象)。
  ディスパッチ用の独自解決を新設しない

## 8. マルチマシン分散(後段)

- `RunOrchestrator` の worker 抽象(デバイス+ブリッジ単位)をマシン跨ぎへ拡張し、
  シナリオバッチを複数 Mac に割り当てる
- results DB のマージ・JUnit 集約・レポート内パスの書き換え(手元で開ける形に)が必要
- デバイス選定は**リモート側のマシンプロファイルで解決**する(machines/ が既に
  マシン単位の概念を持つ)

## 9. 未検証事項(実装前に潰す)

| 項目 | 確認方法 |
|---|---|
| **`launchctl asuser` で Aqua 到達が成立するか**(シミュレータ・XCUITest・FM が動くか) | localhost へ SSH → asuser で自セッションに注入して run。不成立なら §5 の代替(gui domain bootstrap / スプール監視 LaunchAgent)へ切替 |
| FM のヘッドレス/ロック中挙動 | ロック状態で `ftester doctor --fm-only` を反復(availability は嘘をつくので実呼び出し) |
| Android `-no-window` の凍結挙動 | §6 の対照実験 |
| SSH ディスパッチの体験成立 | 手動 SSH + `launchctl asuser` で隣の Mac に run を投げ、成果物回収まで通す |
| 遠隔での flake 診断コスト | 上の素振りで、失敗時にレポートだけで切り分けられるか確認 |

## 10. 作業計画

各 Phase の末尾が判断ゲート。**Phase 0 で需要または体験が成立しなければ中止**(以降を作らない)。

### Phase 0: 素振り・検証(実装なし)

- 手動 SSH + `launchctl asuser` で隣の Mac へ run を投げる(転送→install.sh→run→回収を手作業)
- §9 の未検証5項目を実測(先頭は asuser の成立可否 — Phase 1 の到達経路を決める)
- **ゲート**: 対話的分散・共有の需要が実在するか/ジョブ粒度の体験が成立するかをユーザーが判断

### Phase 1: `ftester run --host <mac>`(単一リモート・ジョブ粒度)

- 適合チェック(§7)・rsync 転送・リモート実行・出力ストリームバック(§3 の用途分け)・
  成果物回収(JUnit の `report:` パス書き換え含む)
- Aqua への到達は Phase 0 で成立を確認した経路を使う。`launchctl asuser` が不成立
  だった場合は **Phase 2 の session agent をここへ繰り上げる**(計画の分岐点)
- 純粋ロジック(適合判定・転送対象の算出・回収パス書き換え)は切り出して単体テスト。
  SSH 越しの結合は E2E に残す
- 新スクリプト/サブコマンドを足したら Bash 許可リストにも足す(承認3方向の②)
- **ゲート**: 実デバイスの run 1本が手元 CLI から見えて成果物が開けること。
  加えて**2回目以降のディスパッチ所要(転送+増分ビルド)を計測**し、体験成立の
  判断材料にする(コールドビルド数分は初回のみか、を確認)

### Phase 2: session agent 常設化 + 運用ドキュメント

- LaunchAgent 版 session agent(受けて spawn して中継するだけ+**ジョブ直列化**[§5])
- **control(Background)→ execution(Aqua)の受け渡し IPC をここで決める**
  (候補: スプールディレクトリ監視 vs localhost ソケット。設計判断として記録する)
- ランナー機セットアップ手順の文書化(自動ログイン・ロック無効・LaunchAgent・
  セキュリティ注意)。ci.md のランナー前提と整合させる
- **ゲート**: ランナー機の再起動後、人手なしで受付可能に戻ること。同時ディスパッチ
  2本が直列化されること

### Phase 3: マルチマシン分散

- `RunOrchestrator` worker のマシン跨ぎ拡張・results DB マージ・JUnit 集約
- ToolchainFingerprint によるフリート適合チェック(不適合機は除外して警告)
- **ゲート**: 2台分散で壁時計が短縮され、失敗レポートが手元から辿れること

### Phase 4(任意): Android ヘッドレスレーン

- §6 の採用条件2つが実測で成立した場合のみ。ディスパッチの振り分け(対象 OS・FM 使用)を追加

## 11. GUI(vscode-ftester モニター)への影響

リモートデバイスをローカルと混在表示する場合に必要になる機能。優先度は Phase 対応表(末尾)。

### マシン軸の導入

- デバイスモデル(monitorDeviceModel)に **host 属性**を追加し、タイルをホスト別に
  グルーピング+ホストバッジ表示。**デバイス名は全 Mac で衝突する**(どのマシンにも
  「iPhone 17」がいる)ため、名前だけの識別は混在時点で成立しない
- hostCharts(負荷チャート)はローカル1台前提 → ホスト別の行に分割
- machines プロファイルの表示・編集は「どのマシンの」の次元が増える

### ホスト状態(デバイス状態の上の新しい階層)

- 到達可能 / SSH 不可 / session agent 不在 / 版スキュー(rev・Toolchain・Protocol)/
  FM 可否 をホストヘッダに表示(compatCheck / protocolVersion の照合をホスト単位へ拡張)。
  §7 の fail fast の理由を GUI で見せる場所
- 「このホストを更新」は既存方針どおり**設定タブ1箇所**(monitorUpdateController の拡張)
- FM 可否(`doctor --fm-only` 結果)はホスト別に常設表示(screenIs を含むスイートの
  振り分け判断に直結)

### ストリーミングの帯域制御と stale の意味論変更(最重要)

- リモートタイルの既定は低 FPS/静止サムネイル、**選択時のみライブ化**(可視タイルのみ配信)。
  H.264 全タイル常時配信は LAN 帯域で成立しない
- **フレーム経過秒をタイルに表示**。「古いフレーム」の原因が
  デバイス凍結([[emulator-display-freeze-wedge]] の既知の罠)とネットワーク遅延の
  2値になり、表示なしでは切り分け不能
- **watchdog の分界(後付け不可)**: 凍結検知(monitorHealthWatchdog)は
  「フレーム不変=デバイス凍結」前提。リモートではリンク切れでも同じ見え方になるため、
  **ホスト到達性を先に判定してからデバイス凍結と診断する**。入れないとネットワーク瞬断の
  たびに sleep/wake 修復が誤発火する。リモートタイル表示開始(Phase 3 の頭)までに必須

### run レーンとディスパッチ

- レーンにホスト帰属を表示(NDJSON にホストを乗せて流す。JUnit の worker と対応)
- 実行開始 UI に発行先の選択(特定ホスト/自動分散)
- 罠: runLaneModel/runReducer は両バンドル共有 → 新規表示文字列は
  `i18n/strings/lane.ts` のランタイム側(既存の i18n 制約)

### 共有ラボの占有表示とガード

- 占有・所有の表示(どのデバイスがどのジョブ/誰の run か)。複数人共有では
  占有が見えないと相乗り事故になる([[avoid-driving-monitor-owned-devices]] の一般化)
- リモートへの `devices down` 相当は他人の run を殺し得る → ホスト側
  `showWarningMessage({modal:true})` で確認(webview の `window.confirm` は効かない)+
  「自分が起動したものだけ」オプション
- **作らない**: リモートタイルからの対話操作。モニター=受動ビューアの決定を維持

### 成果物・ログ・プロセス管理

- レポート・録画リンクはリモートパスを指す → **クリック時に回収してから開く**
  (録画は大きいのでオンデマンド+withProgress)。実行ログは OUTPUT へ(ホスト別
  チャンネル or 行プレフィクス)
- processesTab / orphanSweep はローカルプロセス走査前提でリモートに適用不能。
  リモートは session agent 経由の状態表示だけにし、**効かない kill ボタンを出さない**。
  掃除はリモート側 ftester の責務

### Phase 対応

| 段階 | 必要になる GUI 機能 |
|---|---|
| Phase 1 | ほぼ不要(CLI 完結)。あるならレーンのホスト表示・成果物のクリック時回収 |
| Phase 2 | ホスト状態表示・設定タブのホスト一覧/更新・FM 可否表示 |
| Phase 3 | タイルのホスト別グルーピング・帯域制御・**watchdog 分界**・占有表示・ディスパッチ UI |

## 関連

- CI 前提・FM の可否表: [ci.md](ci.md)
- 実行アーキテクチャ・AppDriver 境界: [design.md](design.md) §2
- 検証の規律(flake 判定・対照実験の作法): [verification.md](verification.md)
