# リモートランナーのセットアップ

別の Mac(ランナー機)でテストを実行できるようにする手順です。

## 始める前に

- **手元の Mac**: fleetest のセットアップが終わっていて、テストプロジェクトがあること
  ([はじめに](../getting-started_ja.md))。
- **ランナー機**: 次の条件を満たしていること。足りないものはステップ0で整えます。

| 条件 | 確認方法(ランナー機で実行) |
|---|---|
| Apple silicon であること | `sysctl -n hw.optional.arm64` が `1` |
| ログインしていること | `stat -f%Su /dev/console` がランナーのユーザー名と一致 |
| システムスリープが無効になっていること | `sudo pmset -a sleep 0` |
| 画面共有が ON になっていること | システム設定 → 一般 → 共有 → 画面共有 |
| リモートログインが ON になっていること | システム設定 → 一般 → 共有 → リモートログイン |
| 外部からの接続をすべてブロックが OFF であること | システム設定 → ネットワーク → ファイアウォール → オプション |
| Homebrew がインストールされていること | `brew --version` |
| Xcode をインストールしてライセンスに同意していること | `sudo xcodebuild -license accept` → `sudo xcodebuild -runFirstLaunch` |
| 手元の Mac と同じ Xcode の製品版がランナー機のどこかにあること(ベータのビルド番号までは揃えなくてよい) | `xcodebuild -version` |
| Xcode でテストで使用するiOSシミュレーターをダウンロードしていること | `xcodebuild -downloadPlatform iOS` |
| Android Studio をインストールしていること。SDK の場所は既定(`~/Library/Android/sdk`)であること | `fleetest doctor` |

ランナー機の `/Applications` に複数の Xcode を並べて入れておけば、手元の Mac の Xcode の製品版に
合う方を fleetest が自動で選びます(他の版を削除する必要はなく、`sudo` も要りません)。別の場所に
置いた Xcode を使わせたいときは、マシンを登録するとき(ステップ2)に
`--developer-dir <.app へのパス>` でそのパスを指定してください。指定しないと fleetest はその
Xcode を見つけられません。一致する Xcode が無い、または複数が同じくらい一致するときは、
候補の一覧を添えて実行が止まります。

## ステップ0: ランナー機を準備する

👉 **ランナー機で1回だけ作業します。**

ランナー機の前に座るか、画面共有で作業してください。どれも sudo か画面操作が要るので、
fleetest は代わりに行いません。

1. **リモートログインを ON にする**: システム設定 → 一般 → 共有 → リモートログイン。
2. **ファイアウォールを確認する**。**ファイアウォールが OFF なら何もしなくてよい。** ON のときは
   「外部からの接続をすべてブロック」だけを OFF にする(システム設定 → ネットワーク →
   ファイアウォール → オプション)。このオプションが ON の間は SSH も塞がれます。ファイアウォール
   自体は ON のままでかまいません。状態は次のコマンドで確かめられます:
   ```bash
   /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate   # "Firewall is disabled" なら完了
   /usr/libexec/ApplicationFirewall/socketfilterfw --getblockall      # "… set to disabled" なら OK
   ```
3. **画面共有を ON にする**(推奨)。ランナー機が再起動したあと、手元の Mac からログインし直せます。
4. **システムスリープを無効にする**:
   ```bash
   sudo pmset -a sleep 0
   ```
5. **Xcode をインストールしてライセンスに同意する**。手元の Mac と同じ製品版にします(ベータの
   ビルド番号までは揃えなくてよい)。Xcode は <https://developer.apple.com/download/> から
   ダウンロードできます。
   ```bash
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   ```
6. **Android Studio をインストールする**(Android を回すときだけ)。Android Studio は
   <https://developer.android.com/studio> からダウンロードできます。初回起動時のセットアップ
   ウィザードで Android SDK を入れてください。
   - SDK は既定の場所(`~/Library/Android/sdk`)のままにします。fleetest は SSH 越しに動くので、
     `~/.zshrc` などで設定した `ANDROID_HOME` は読まれません。既定の場所なら何も設定しなくてよい。
   - エミュレータ(AVD)は Android Studio の Device Manager で作れます。ステップ4で fleetest から
     作ることもできます。
7. **Homebrew をインストールする**。ステップ3で fleetest が必要なツール(xcodegen)を Homebrew で
   自動で入れるので、Homebrew が要ります。
   - **Homebrew を入れたことがない場合**: ターミナルで次のコマンドを実行します(手順は
     <https://brew.sh/> にもあります)。途中でランナー機のログインパスワードを聞かれます。
     ```bash
     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
     ```
     終わると「Next steps」の下に `brew` を使えるようにするコマンドが表示されます。表示どおりに
     実行し、`brew --version` が動くことを確かめてください。
   - **Homebrew がすでに入っている場合**: `brew --version` が動くことを確かめます。しばらく更新して
     いない Mac では、Homebrew が新しい macOS に対応しておらず、まったく動かないことがあります。
     その場合は次のコマンドで更新します(`brew update` 自体が動かないので、git で更新します)。
     ```bash
     git -C /opt/homebrew fetch origin && git -C /opt/homebrew reset --hard origin/master
     ```
8. **ログインしたままにする**。ログアウトしないでください。画面のロックはかまいません。

まだ足りないものがあれば、ステップ3の `fleetest remote setup` が一覧にして教えてくれます。

## ステップ1: SSH の鍵でログインできるようにする

👉 **手元の Mac で作業します。**

AIエージェントに以下のように依頼してください。
```
user@192.168.xxx.xxx へSSHで接続できるようにして
```
<br>

手動でやる場合は以下を実行してください。
```bash
ssh-copy-id user@192.168.xxx.xxx  # ← 適切なユーザー名とホストに書き換えて実行します
ssh -o BatchMode=yes user@192.168.xxx.xxx 'echo ok'  # ok と表示されれば準備完了です
```

## ステップ2: マシンを登録する

👉 **手元の Mac で作業します。**

### VSCode 拡張で登録する

1. コマンドパレットで `fleetest: デバイスモニターを表示` を実行し、デバイスモニターを開きます。
2. 「設定」タブを開き、「マシン」の表の「リモートホストを追加」を押します。表に新しい行が
   追加されます。
3. 「user@host」に SSH の宛先を入れます(例: `user@192.168.xxx.xxx`)。
4. 「マシン(任意のエイリアス)」にマシン名を入れます(例: `M1Max`)。
5. 「作業ベースディレクトリ」と「FM 並列枠」は、デフォルトで構いません。
6. 「確定」をクリックします。

- 行の右端の「−」を押すと、確認のダイアログのあとで登録を削除します。
- 「user@host」とマシン名は、他の行と重複できません(マシン名が空欄なら「user@host」から採った
  名前で比べます。`local` はこの Mac の名前です)。重複していると保存せず、該当する欄に枠を付けて
  表の下に理由を出します。
- 「バッジ色」のボタンを押すと、バッジの色をパレットから選べます。選ばなかった場合は、
  他のマシンと重ならない色が自動で付きます。色はデバイスモニターのマシン名バッジに使われます。
- 「マシン有効」(バッジ色の右・既定 ON)を外すと、そのマシンへはテストを振り分けません。
  実行プロファイルのうちそのマシンに居るデバイスは使わず、シナリオは残りのマシンへ配られます。
  この Mac の行にもあります。`--runner` でマシンを明示した実行は、外していてもそのマシンで走ります。

### CLI で登録する

```bash
fleetest remote machines add <マシン名> --host user@192.168.xxx.xxx
fleetest remote machines        # 登録を確認する
```

- 別のマシン名で登録済みの宛先は登録できません。

- マシン名に使えるのは英数字と `_` `.` `-` だけです。`local` は手元の Mac を表す名前なので使えません。
- 同じ名前でもう一度 `add` すると、登録を上書きします。
- 登録を消すときは `fleetest remote machines remove <マシン名>` です。
- このランナーに使わせたい Xcode が `/Applications` 以外の場所にあるときは、
  `--developer-dir <.app へのパス>`(例: `--developer-dir /Applications/Xcode_27.app`)を付けて
  固定します。ランナーの `/Applications` に、使うそれぞれの製品版の Xcode が1つずつしか無いなら
  付けなくて構いません。

CLI と拡張は同じ登録簿(`~/.config/fleetest/config.json`)を読み書きします。どちらで登録しても結果は同じです。

## ステップ3: ランナー機に fleetest を入れる

👉 **手元の Mac で作業します。**

ターミナルで次のコマンドを実行します。

```bash
fleetest remote setup <マシン名> --project <プロジェクト>
```

- 初回はビルドがあるので数分かかります。
- 何度実行しても構いません。途中で止まっても、直してから同じコマンドをもう一度実行すれば続きから進みます。

## ステップ4: ランナー機のデバイスを実行プロファイルに入れる

👉 **手元の Mac で作業します。**

どのデバイスでテストを実行するかは、実行プロファイルの `devices` で決めます。デバイス1台ごとに
`machine` を直接持ちます。プロファイルは手元で編集し、実行のたびにランナー機へ自動で送られます。
ランナー機のファイルを直接編集する必要はありません。

### VSCode 拡張で入れる

1. デバイスモニターの「プロファイル」タブで、ランナー機のデバイスを使わせたい実行プロファイルを
   開きます。
2. 「デバイスを追加」の「+」を押します。「デバイスを選択」が開きます。
3. 上部の「マシン:」で <マシン名> を選びます。一覧が、ランナー機にあるデバイスに切り替わります
4. 使うデバイスにチェックを入れます。使いたいデバイスが無ければ、「デバイスを作成」の「+」から
   ランナー機の上に作れます。作成の前に「「<デバイス名>」を M1Max 上に作成します。よろしいですか?」と
   確認が出るので、「作成」を押します。
5. 「OK」を押します。手元の実行プロファイルの `devices` に、`"machine": "M1Max"` の付いた
   デバイスが追加されます。
6. 実行プロファイルの「デバイス」で、追加したデバイスにチェックが入っていることを確認します。

### CLI で入れる

1. ランナー機にあるデバイスを確認します。
   ```bash
   fleetest remote exec M1Max -- api installed-devices
   ```
2. 実行プロファイル(`TestProjects/<プロジェクト>/profiles/runs/<名前>.json`)の `devices` に、
   `machine` を付けてデバイスを書きます。
   ```jsonc
   { "devices": [
       { "platform": "ios", "machine": "M1Max", "name": "iPhone 17 Pro-01",
         "osVersion": "iOS 27.0", "model": "iPhone 17 Pro", "udid": "<UDID>" } ] }
   ```

### プロファイルを作るときの注意

- **手元のデバイスには `"machine": "local"` と書きます**。拡張で追加した場合は自動でそうなります。
- 手元とランナー機のデバイスを、1つの実行プロファイルに混ぜても構いません。シナリオは
  マシンごとのデバイスの台数に応じて振り分けられ、同時に実行されます。
- **アプリは手元でビルドしておきます**。アプリプロファイルの `appPath` が指すアプリは、実行のたびに
  手元からランナー機へ自動で送られます。ランナー機でアプリをビルドする必要はありません。

## ステップ5: つながるか確認する(手元の Mac で)

### CLI で確認する

```bash
fleetest remote status --runner M1Max
```

```
HOST          REACHABLE  LOGIN  REV          TOOLCHAIN     RUNTIME             FM  BINARY  FREE
user@mac2     yes        yes    ✅ 9655a21…  ✅ Xcode26…   ✅ iOS 27.0: 24A434  -   yes     412 GB
```

| 表示 | 意味 | 対処 |
|---|---|---|
| `LOGIN` が `no` | ランナー機がログイン画面で止まっている | 画面共有などでログインします |
| `REV` に ⚠️ | 手元とツール本体の版がずれている(実行は止まります) | `fleetest remote setup M1Max` をもう一度実行します |
| `TOOLCHAIN` に ❌ | 手元の Mac の製品版に一致する Xcode がランナー機に無い、または複数が同じくらい一致する(実行は止まります) | 一致する製品版の Xcode をランナー機へ追加で入れます(他の版を消す必要はありません)。複数あって絞れないときは `--developer-dir` で固定します |
| `TOOLCHAIN` に ⚠️ | Xcode は同じ製品版だがベータのビルド番号が違う(実行は止まりません) | 揃えなくても実行できます。揃えたい場合は両方の Mac を同じビルドにします |
| `RUNTIME` に ⚠️ | ランナー機の iOS シミュレータのランタイムが手元と違う | ランナー機で `xcodebuild -downloadPlatform iOS` を実行します(警告だけで、実行は止まりません) |
| `RUNTIME` に ⚠️ `iOS <版>: none` | そのランナー機に、使われている Xcode に対応するシミュレータのランタイムが無い(ランタイムは Xcode に付いてきません)。その iOS の台を作れません | そのランナー機で `xcodebuild -downloadPlatform iOS` を実行します |
| `BINARY` が `no` | ランナー機に fleetest がビルドされていない | ステップ3をもう一度実行します |

### VSCode 拡張で確認する

デバイスモニターを開くと、ランナー機のデバイスも手元のデバイスと同じようにタイルで表示されます。
タイルにはマシン名のバッジが付きます。

- タイルが「状態不明」のままのときは、ランナー機の fleetest の版が手元と揃っていないか、
  SSH で接続できていません。ステップ3をもう一度実行してから、ツールバーの「モニター再起動」を
  押してください。
- ツールバーのグラフ(MEM/CPU など)には、マシンごとの行が出ます。

## ステップ6: 最初のテストを実行する(手元の Mac で)

初回はランナー機でシナリオのビルドなどがあるので、始まるまで数分かかります。2回目からは数秒で
始まります。レポート・録画・ログは手元の Mac へ回収されます。

### CLI で実行する

```bash
fleetest run --profile <実行プロファイル> --scenario <シナリオID>
```

実行プロファイルのデバイスに `"machine": "M1Max"` が書いてあれば、`--runner` を付けなくても
ランナー機で実行されます。この1回だけ別のマシンへ送りたいときは `--runner M1Max` を付けます。

**Android では、先にエミュレータを起動しておきます**(iOS のシミュレータと違い、自動では起動しません):

```bash
fleetest remote exec M1Max -- devices up --profile <実行プロファイル>
```

### VSCode 拡張で実行する

1. コマンドパレットで `fleetest: 実行プロファイルを選択` を実行し、ステップ4の実行プロファイルを選びます。
2. デバイスモニターのツールバーの「テストを実行」を押します。デバイスを起動してから、テストを実行します。
   テストエクスプローラーから実行することもできます。

実行を始める前に、拡張はランナー機の fleetest の版が手元と揃っているかを確認します。

- ずれているときは「リモートのfleetestのバージョンが本機と異なります」と出ます。
  「更新して実行」を押すと、ランナー機を手元と同じ版に揃えてから実行します。
- 揃えられないとき(手元の変更を push していない、ランナー機に接続できない、Xcode の製品版が
  違う、など)は「リモートのfleetestを更新できないため実行できません」と理由が出て、実行は止まります。
  **Xcode がベータのビルド番号だけ違うときは実行は止まりません**(警告だけ)。

## fleetest を更新したとき

手元の fleetest を更新したら、ランナー機も同じ版に揃えます。揃っていないと、実行は始まりません。

- **CLI**: `fleetest remote setup M1Max` をもう一度実行します。版を揃えるだけなら
  `fleetest remote align M1Max` でも構いません。
- **VSCode 拡張**: テストを実行するときに出る「更新して実行」で揃えられます。

## 1台のランナー機を複数人で使うとき

- 各自の手元の Mac で `~/.config/fleetest/config.json` に `issuerId`(自分の名前。例: `tanaka@dev-mbp`)を
  書いておきます。ランナー機の上の作業場所の名前にもなるので、決めた値を変えないでください。
- **各自が1回ずつ `fleetest remote setup M1Max` を実行します**。自分用の作業場所がランナー機に
  作られます。
- 同時に実行できるのは1人だけです。待ち方などは[リモート実行](remote_runners_ja.md)の
  「1台のランナー機を複数人で使うとき」を見てください。

## うまくいかないとき

| メッセージ・症状 | 原因 | 対処 |
|---|---|---|
| `cannot reach … over ssh` | 鍵でログインできない、または宛先が違う | ステップ1をやり直します |
| `must not contain ':'` | 宛先にポート番号を書いた(`host:2222`) | `~/.ssh/config` に別名を作り、その別名を宛先にします |
| `remote setup` が終了コード `2` で終わる | ランナー機に人の手が要る項目が残っている | 出力に並んだ項目を直し、同じコマンドをもう一度実行します |
| `neither xcodegen nor Homebrew is available` | ランナー機に Homebrew が入っていない | ステップ0の7で Homebrew を入れてから、`fleetest remote setup` をもう一度実行します |
| `is sitting at the login window` | ランナー機がログイン画面で止まっている | 画面共有などでログインします |
| `git revision mismatch` | 手元とランナー機の版がずれている | `fleetest remote setup M1Max` をもう一度実行します |
| `toolchain mismatch` | 手元の Mac の Xcode 製品版に一致する Xcode がランナー機に無い(macOS の版は関係ありません。ベータのビルド番号だけの違いではこのメッセージは出ません) | 一致する製品版の Xcode をランナー機の `/Applications` へ追加で入れます(既に入っている版を消す必要はありません) |
| `could not tell which installed Xcode to dispatch with: … match this Mac's product version` | ランナー機に、手元の Mac の製品版に一致する Xcode が複数ある | 使わせたい方を固定します: `fleetest remote machines add <マシン名> --host <宛先> --developer-dir <.app へのパス>` |
| `could not tell which installed Xcode to dispatch with: none of the …` | ランナー機に手元と一致する Xcode が1つも無い(メッセージが見つかった Xcode を全部並べます) | その製品版の Xcode をランナー機へ追加で入れます(他の版は消さなくて構いません)。固定しても直りません |
| `no runner workspace at …` | ランナー機にあなたの作業場所がまだ無い | `fleetest remote setup M1Max` を1回実行します |
| `no running emulator for AVD …` | Android のエミュレータが起動していない | ステップ6の `devices up` を実行します |
| `app package not found at …` | 手元の `appPath` にアプリが無い | 手元でアプリをビルドするか、`appPath` を直します |
| タイルが「状態不明」のまま | ランナー機の fleetest の版が古い、または SSH で接続できない | ステップ3をもう一度実行し、ツールバーの「モニター再起動」を押します |

ここに無いメッセージは、[docs/remote-runner-setup.md](../../remote-runner-setup.md) の
「うまくいかないとき」にまとめてあります。

### Link
- [index](../index_ja.md)
- [リモート実行](remote_runners_ja.md)
