# ネットワークの露出とセキュリティ

[in English](network_security.md)

社内 LAN(インターネットに出さない企業内ネットワーク)で運用する利用者が、情シス/セキュリティ
担当に「このツールは何をどこに開くのか」を説明するための要点です。導入の手順書ではありません。
テストコード(シナリオ)が触れるファイルと通信先を絞る仕組みは[サンドボックスを確かめて、必要な穴をあける](sandbox_ja.md)にあります。

## 待ち受け(listen)の一覧

| 何 | どこに開くか | 認証 |
|---|---|---|
| 手元の Mac(CLI・MCP サーバー・モニター・ライブ操作) | **外向けのポートを1つも開かない**。すべて標準入出力の NDJSON で親子プロセス間だけ | — |
| シナリオのサンドボックスのプロキシ | `127.0.0.1` のみ。`sandbox.allowedDomains` を書いたときだけ起動し、ポートは起動のたびに変わる | 不要(ループバック。中継するのは `allowedDomains` の宛先だけ) |
| iOS Simulator のブリッジ(XCUITest / in-app) | デバイス内の `127.0.0.1` のみ。Simulator はホストとネットワークスタックを共有するので手元から届く | 不要(ループバック) |
| Android のブリッジ(実機・Emulator 共通) | **デバイス内のループバックのみ**。手元へは `adb forward` が張る動的なローカルポート経由 | 不要(ループバック) |
| Android Emulator の gRPC | `127.0.0.1` | Emulator 自身が発行するブート毎の Bearer トークン |
| **iOS 実機・USB 経路(既定・推奨)** | iproxy(libimobiledevice)の USB トンネル。**すべてループバックに留まる** | 不要(ループバック) |
| **iOS 実機・LAN 経路** | **端末の全インターフェース**。同じ LAN から届く | **トークン必須**(下記) |
| compose.yaml の公開ポート(`scripts/compose.yaml` を持つプロジェクトの run) | 通常 `127.0.0.1`。実機のレーンがある run と `services up --physical` では `0.0.0.0` | 不要 |
| fleetest のプロキシ(Apple Container で `allowedDomains` があるとき) | コンテナ網のゲートウェイ IP | 不要(中継するのは `allowedDomains` の宛先だけ) |
| ランナー機のリモートログイン(SSH)。リモート実行を使うときだけ、ランナー機で ON にする | ランナー機の 22 番 | 鍵認証 |
| ランナー機の画面共有(推奨。リモート実行を使うときだけ、ランナー機で ON にする) | ランナー機の 5900 番。ルーターで開けない | macOS の認証 |

- ブリッジのポートは **8123〜8154 の 32 本**(iOS)。
- **iOS 実機で LAN 経路が選ばれる条件は2つ**: ①その Mac に iproxy が入っていない ②端末が USB で
  なく Wi-Fi で繋がっている。どちらかに当てはまると自動で LAN になります。
- **ループバックのブリッジは、ブラウザが送った要求を断ります**。
  認証の無いループバックの待受は、閲覧中の Web ページから `http://127.0.0.1:<ポート>` へ要求を送られたり、
  DNS リバインディング(ホスト名を `127.0.0.1` へ向け直して応答まで読む)を受けたりしえます。そこで
  `Origin` ヘッダ付きの要求、`Sec-Fetch-Site` が `none` 以外の要求、ループバック以外を宛先にした `Host` の要求を
  **403** で断り、端末には触れません。fleetest 自身のクライアントは、これらのヘッダを付けません。
- **in-app ブリッジは製品ビルドに混入しません**。アプリ起動時に `DYLD_INSERT_LIBRARIES` で
  差し込むだけで、アプリのバイナリにリンクされません。

## LAN 経路のトークン認証

- ブリッジを起動するたびにホストが **32 バイトの乱数**を作り、テストランナーの環境変数として
  渡します。
- 手元からの要求は毎回 `X-FT-Token` ヘッダで送ります。**一致しなければ 401** を返し、端末には
  一切触れません。比較は定数時間です。
- **トークンが無いまま全インターフェースに開くことはできません**(ランナーが起動を拒否します)。
- トークンは `.fleetest/bridge-<ポート>.endpoint`(作業フォルダのルート。`TestProjects/<プロジェクト>/` の中ではありません)に置かれ、**引数や環境変数で
  他のプロセスへ渡りません**(`ps` で見えないようにするためです)。
- **これは同じ LAN 上の第三者を防ぐためのものです**。ループバックの経路には認証が無く、その
  Mac にログインできる人は元から同じことができます。

## 外向きの通信

- **テレメトリ・解析データの送信は一切ありません**。
- Apple Intelligence(Foundation Models)は**端末内で動きます**。外へは出ません。
- **テスト対象アプリを Google へ送りません。** Android の `adb install` は Play Protect の照会で
  止まることがあるため、インストールの間だけ検証を切って必ず元に戻します。
- 外へ出るのは、**導入・更新・更新の有無の確認(VSCode 拡張が1日1回、`git ls-remote` で)・Android の
  システムイメージの取得**のときだけです。**テストの実行中は外へ出ません**(シナリオが
  `sandbox.allowedDomains` に書いた宛先へ通信する分と、compose.yaml を持つプロジェクトの run が手元に無いイメージをコンテナレジストリ(docker.io 等)から取得する分を除きます。
  中継用のイメージも docker.io の alpine から作ります。自分でビルドしたイメージを `image:` に書けば取得は起きません。閉じたネットワークでは先に
  `fleetest services pull` か `fleetest services load <tar>` で載せます。何も書かなければシナリオは外へ一切出られません。
  [サンドボックスの既定](../reference/running/sandbox_access_ja.md))。

| 何を取りに行くか | 行き先 | いつ |
|---|---|---|
| 導入スクリプト | `raw.githubusercontent.com` | 導入・更新 |
| fleetest 本体 | `github.com` | clone・pull・更新の有無の確認 |
| **Swift の依存 20 本超** | `github.com`(`apple/*`・`grpc/*`・`swiftlang/*`・`swift-server/*`・`jpsim/Yams`) | `swift build` |
| VSCode 拡張の依存 8 個 | `registry.npmjs.org` | 拡張のビルド |
| `node@26`(VSCode 拡張のビルド用)・`libimobiledevice` | Homebrew の配信元 | 導入時 |
| Android のシステムイメージ・コマンドラインツール | `dl.google.com` | Emulator を作るとき・Android SDK のツールを入れるとき |
| コンテナイメージ(compose.yaml を使うとき) | コンテナイメージのレジストリ(docker.io) | run の開始時・`fleetest services pull` |

**量が一番大きいのは Swift の依存**で、fleetest 自身のリポジトリではありません。
Android ブリッジの APK はリポジトリに同梱してあるため、Android のビルドツールは要りません。

## ファイアウォールの設定

### シナリオの外向きの通信を絞るのはサンドボックス

macOS のファイアウォール(システム設定 → ネットワーク → ファイアウォール)は、**外から入ってくる接続**をアプリ単位で
止める仕組みで、シナリオが外へ出る通信は絞れません。シナリオの外向きの通信を宛先ごとに許可するのは
`sandbox.allowedDomains` です([サンドボックスの既定](../reference/running/sandbox_access_ja.md)の「通信先」)。
**何も書かなければ外部へは一切出られない**ので、追加のファイアウォールは要りません。

- 許可した宛先へ実際に繋ぐのは fleetest 本体(この Mac)です。Mac や社内ネットワークのファイアウォール・プロキシの
  制限はそのまま掛かります。許可していても Mac から宛先へ届かないときは、プロキシが `502 Bad Gateway` を返します。
- **この Mac の localhost で動くローカルプロキシ**(通信の解析ツール・社内プロキシのエージェント・SSH のポートフォワード)が
  あると、シナリオはそれを経由して `allowedDomains` の外へ出られます。信頼できないシナリオを動かす Mac では止めておいてください
  ([注意事項と制限事項](limitations_ja.md))。

### macOS のファイアウォールは ON のままでよい

- **fleetest はこの Mac で外向けのポートを1つも開きません**。CLI・MCP サーバー・モニターは標準入出力でやり取りし、
  ブリッジとプロキシはループバック(`127.0.0.1`)だけで待ち受けます。ループバックはファイアウォールの対象外なので、
  ファイアウォールを ON にしても、アプリごとの許可を足さなくても動きます。**例外は compose.yaml のサービスを使う run の2つ**です:
  Apple Container ではプロキシの転送器がコンテナ網のゲートウェイ IP で待ち受け(上の表)、実機のレーンがある run では
  サービスの公開ポートが全インターフェースに開きます(そうすることへの同意が、マシン設定 `services.publishForPhysicalDevices`)。
- iOS 実機を Wi-Fi で使うときも、待ち受けるのは端末の側で、Mac は繋ぎに行くだけです。Mac 側の設定は要りません。
- **リモートランナーにする Mac だけ**は、ファイアウォールの「外部からの接続をすべてブロック」を OFF にしてください
  (ON だと SSH も塞がれます。ファイアウォール自体は ON のままで構いません)。手順は
  [Mac を追加する](../fleet/adding_mac_ja.md)にあります。

### 社内のファイアウォール

テストの実行中、fleetest 本体は外へ出ません(シナリオが `allowedDomains` へ通信する分を除きます)。外へ出るのは
導入と更新のときだけで、その行き先は上の「外向きの通信」、閉域網での運用は下の「閉域網(インターネットに出さない場合)」にあります。

## 閉域網(インターネットに出さない場合)

### 方針 A(推奨): 上の行き先だけ HTTPS を通す

許可する宛先は5つ(`raw.githubusercontent.com` / `github.com` / `registry.npmjs.org` /
Homebrew の配信元 / Android を使うなら `dl.google.com`)と、compose.yaml を使うならコンテナイメージのレジストリ(docker.io)だけです。テレメトリが0件で、**テスト実行中は外へ出ない**ことを添えれば、
例外申請の説明がつけやすい形です。**ツール側に追加の設定は要りません。**

### 方針 B: 社内ミラー(A が通らない場合)

git の `insteadOf` で GitHub 宛てを**丸ごと**差し替えます。`Package.swift` も `Package.resolved` も
書き換えないので、上流の版が上がっても追随が要りません。

```
git config --global url."https://<社内ミラー>/".insteadOf "https://github.com/"
```

これだけで **fleetest 本体と Swift の依存 20 本超が同時に**ミラー経由になります。

SwiftPM もこの設定に従うので、依存の取得は `github.com` ではなくミラーへ向きます。

残るのは3つ:

- **導入スクリプト**: `insteadOf` は git にしか効かず `curl` には効きません。**先にクローンして
  `bash <TOOL_ROOT>/Scripts/install.sh` を直接実行**してください(curl 形は使えません)。
  更新も同じく `bash <TOOL_ROOT>/Scripts/update.sh` を使います
- **npm**: `.npmrc` の `registry` を社内プロキシへ向けます
- **Homebrew**: 社内 tap を用意するか、`node@26` と `libimobiledevice` を事前に入れておきます

初回のクローンだけを差し替えるなら `FLEETEST_REPO_URL=<ミラーの URL>` も使えます。

### 版の固定

**利用者に版を固定させる導線はありません**(配布口は最新のリリースタグ)。閉域網ではその必要も
ありません —— **ミラー側へ新しいリリースタグをいつ入れるかが、そのまま社内のリリース関門になる**ためです。
利用者の手順を1つも変えずに、取り込む版を制御できます。

## リモートランナー(別の Mac へ実行を投げる場合)

経路は **SSH の鍵認証だけ**です。信頼モデルとランナー機に載るものは[リモート実行](../fleet/remote_runners_ja.md)の
「安全に使うために」にあります。

**ランナー機も、手元の Mac と同じ宛先へ出ます**。`fleetest remote setup` と版を揃えるたびに、ランナー機は
GitHub から fleetest を取得してビルドします。閉域網では、上の方針 A / B をランナー機にも当ててください。

## 運用側で決めること

1. **実機 iPhone を使うすべての Mac に `brew install libimobiledevice` を入れる。** USB
   トンネルになり、LAN への露出が無くなります(通信も速くなります)。
2. Wi-Fi 接続の実機をどうしても使うなら、**テスト用の端末とランナー機をセグメント分けした
   VLAN に置く**。
3. 閉域網なら、まず**方針 A の行き先を許可できるか**を確かめる(上の「閉域網」の方針 A)。
   通らなければ社内ミラー(方針 B)。**どちらも決めずに始めると導入も更新もできません。**
4. **本番の資格情報をシナリオ・プロファイルに書かない。**

## 自分の Mac で確かめる

ここまでの説明が、自分の Mac で本当に成り立っているかを確かめる手順です。どれも読み取りだけで、設定は変えません。

### 1. 待ち受けているポートを見る

fleetest が使うポートは、ブリッジの 8123〜8154 です。外から届く形(全インターフェース)で開いていないことを確かめます。

#### AIへの指示文

```text
この Mac で TCP の待ち受けを調べて。lsof -nP -iTCP:8123-8154 -sTCP:LISTEN の結果を、アドレスが 127.0.0.1(ループバック)のものと、* や 0.0.0.0(全インターフェース)のものに分けて教えて。あわせて fleetest doctor も実行して、警告があれば教えて。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
lsof -nP -iTCP:8123-8154 -sTCP:LISTEN    # ブリッジのポート
lsof -nP -iTCP -sTCP:LISTEN | grep -i fleetest    # fleetest 自身の待ち受け
fleetest doctor
```

</details>
<br>

期待する結果:

- 1つ目は、動いているブリッジの行です。何も動いていなければ何も出ません。アドレス(`NAME` 列)が `127.0.0.1:8123` や
  `localhost:8123` の形ならループバックだけです。Wi-Fi で繋いだ iOS 実機のブリッジは実機の上で待ち受けるので、
  この Mac の一覧には出ません(シナリオを動かしている間だけ、fleetest の中継が `127.0.0.1:<ポート>` で出ます)。
- 2つ目は、fleetest 自身の待ち受けです。ふだんは何も出ません。`allowedDomains` を書いてシナリオを動かしている間だけ、
  `127.0.0.1` に上がったプロキシの行が出ます(ポートは起動のたびに変わります)。
- `fleetest doctor` は、古いブリッジの残りと、Docker の管理口が TCP で公開されている状態を警告として出します。
  何も出なければ、その警告は無い状態です。

### 2. 外向きの通信が `allowedDomains` に絞られているのを見る

この Mac の `sandbox.allowedDomains` を読み、シナリオが通信できる宛先がその一覧だけであることを確かめます。

#### AIへの指示文

```text
~/.config/fleetest/config.json の sandbox.allowedDomains に何が書いてあるか教えて。ファイルが無い、または sandbox が無い場合はそう教えて。編集はしないで。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
cat ~/.config/fleetest/config.json
```

</details>
<br>

期待する結果:

- `allowedDomains` に並んだ宛先だけが、シナリオから届く外部です。ファイルが無い・`allowedDomains` が無い・空なら、
  シナリオは外部へ一切出られません。Wi-Fi で繋いだ iOS 実機のブリッジへは、fleetest 本体がこの Mac の
  `localhost` に張る中継(そのシナリオが動いている間だけ・その実機のブリッジにだけ繋ぐ)を通って届きます。
- 一覧にある宛先でも、シナリオが自作の `URLSession` で直接繋ぐ通信は届きません(プロキシを通る `httpRequest` と
  `fleetestURLSession` だけが届きます)。一覧に無い宛先へ繋ごうとすると、プロキシが `403 Forbidden` を返します。
  実際に繋いで確かめる手順と、繋がらないときの見方は[シナリオから外部へ通信する](../reference/writing/network_access_ja.md)にあります。
- 各キーの意味は[マシン設定(config.json)](../reference/project/machine_settings_ja.md)にあります。値を書き換えるのは
  この Mac の人が手で行います(AI には書かせません)。

### 3. 閉域網の設定が効いているか確かめる

閉域網で運用する場合に、方針 A(行き先を許可)か方針 B(社内ミラー)のどちらかが通っていることを確かめます。

#### AIへの指示文

```text
閉域網の設定が効いているか確かめたい。git の insteadOf の設定と、github.com の foundation-tester への git ls-remote と、raw.githubusercontent.com / github.com / registry.npmjs.org / dl.google.com への HTTPS の到達(状態コード)を調べて、結果を教えて。設定は変えないで。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
git config --global --get-regexp '^url\..*\.insteadof$'
git ls-remote https://github.com/wave1008/foundation-tester.git HEAD
for h in raw.githubusercontent.com github.com registry.npmjs.org dl.google.com; do
  curl -sS -m 10 -o /dev/null -w "$h %{http_code}\n" https://$h/
done
```

</details>
<br>

期待する結果:

- (1)は方針 B の設定です。`url.https://<社内ミラー>/.insteadof https://github.com/` の行が出れば、GitHub 宛ての git が
  ミラーへ向きます。何も出なければ差し替えはありません(方針 A で運用)。
- (2)は、コミットのハッシュと `HEAD` の行が返れば、fleetest 本体の取得が通っています(方針 B ならミラーを通った結果です)。
  `Could not resolve host` や `Connection timed out` で終われば通っていません。
- (3)は、宛先ごとに HTTP の状態コードが並びます。数字(`200` や `301` など)が出ればその宛先へ届いています。`000` と
  エラーが出た宛先は届いていません。方針 B では `raw.githubusercontent.com` と `github.com` は届かなくても構いません
  (導入は先にクローンして `Scripts/install.sh` を直接実行します)。Homebrew の配信元はここに含めていません。
  使っている配信元を情シスに確かめてください。

### Link
- [index](../index_ja.md)
