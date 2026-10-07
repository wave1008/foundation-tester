# 実機を追加する

[in English](adding_physical_devices.md)

本物の iPhone / Android(実機)をフリートに入れて、テストに使えるようにする手順です。実機は、USB でつないだ
Mac のデバイスとしてフリートに加わります。手元の Mac につなぐことも、ランナー機につなぐこともできます
(全体像は[フリートの考え方](concepts_ja.md))。

| ステップ | iOS | Android |
|---|---|---|
| 1. Mac を準備する(Mac ごとに1回) | 署名の設定・USB トンネル | adb があること |
| 2. 端末を準備する(端末ごとに1回) | デベロッパモード・自動ロック | USB デバッグ・画面ロック |
| 3. 実機用のアプリを用意する | 署名済みのビルド | いつもの APK |
| 4. 実行プロファイルに入れる | 共通 | 共通 |
| 5. 動かしてみる | 初回は端末で許可を3つ | — |

AIアシスタントに頼むときは、つないだ端末を機種名で伝えてください(例:「USB でつないだ iPhone 15 を、fleetest の
実行プロファイル ios-physical に登録して」)。人の手が要るステップ(端末の設定・Xcode へのサインイン)は、
AIアシスタントは代わりに行いません。

## iOS

### 1. Mac を準備する

👉 **実機をつなぐ Mac で、1回だけ作業します。**

1. **USB トンネルを入れる**:
   ```bash
   brew install libimobiledevice
   ```
   入れないと、USB でつないでいても Wi-Fi(LAN)経由で通信します。LAN 経由は1往復が約 10 倍遅く、
   途中で接続が切れることもあります。また、ブリッジが同じ LAN に開きます([ネットワークの露出とセキュリティ](../in_action/network_security_ja.md))。
2. **Xcode に Apple ID でサインインする**: Xcode → Settings → Accounts。テスト用のブリッジを実機に入れるために、
   開発用の署名が要ります。
3. **Team ID と bundle ID の接頭辞を設定する**: `~/.config/fleetest/config.json` に書きます。
   ```json
   {
     "developmentTeam": "ABCDE12345",
     "bundleIDPrefix": "io.github.yourname"
   }
   ```
   - `developmentTeam` は Apple Developer の Team ID(10 文字)です。署名証明書の OU の値で、次のコマンドで確かめられます。
     `security find-identity` の括弧の中の値は証明書の ID で、Team ID ではありません。
     ```bash
     security find-certificate -c "Apple Development: <あなたの名前>" -p | openssl x509 -noout -subject
     ```
   - `bundleIDPrefix` は、自分のドメインか `io.github.<ユーザー名>` のような、他のチームと重ならない値にします。
     既定の `com.example` のままだと、他のチームの App ID とぶつかって署名に失敗することがあります。
     同じチームで複数の Mac を使うときは、同じ値に揃えます。
   - 環境変数 `FT_DEVELOPMENT_TEAM` / `FT_BUNDLE_ID_PREFIX` でも指定でき、設定ファイルより優先されます。
   - 署名の設定は Xcode の Signing & Capabilities では直せません。fleetest がビルドのたびにこの値で上書きします。

### 2. 端末を準備する

👉 **端末ごとに1回だけ作業します。**

1. **USB で Mac につなぎ、「このコンピュータを信頼」で「信頼」を選びます。**
2. **デベロッパモードを ON にする**: 設定 → プライバシーとセキュリティ → デベロッパモード。端末が再起動します。
3. **自動ロックを切る**: 設定 → 画面表示と明るさ → 自動ロック → なし。fleetest は画面の消えた端末を起こせません。
   待ちの長いステップの最中に画面が消えると、以後のアプリの起動が断られて実行が止まります。

### 3. 実機用のアプリを用意する

実機には、**実機向けに署名したビルド**(`.ipa` または `.app`)が要ります。Simulator 向けのビルドは入りません
(`The executable contains an invalid signature` で失敗します)。

アプリプロファイルの `appPathPhysical` に、実機用のビルドのパスを書きます(VSCode 拡張では「実機用パッケージパス」)。
Simulator 用の `appPath` と並べて書けます([プロファイル](../reference/project/profiles_ja.md))。

アプリが接続先のサーバを焼き込む場合、実機から見た `127.0.0.1` は端末自身です。Mac で動くサーバに繋がせるなら、
Mac の LAN のアドレスを焼き込んだビルドを使います。

## Android

### 1. Mac を準備する

Android SDK(adb)があれば、追加の準備は要りません。`adb devices` が動くことを確かめます。

### 2. 端末を準備する

1. **USB デバッグを ON にする**: 設定 → デバイス情報 → ビルド番号 を7回タップして開発者向けオプションを出し、
   設定 → システム → 開発者向けオプション → USB デバッグ を ON にします(項目の場所は機種によって違います)。
2. **USB で Mac につなぎ、「USB デバッグを許可しますか?」で「このパソコンからの USB デバッグを常に許可する」に
   チェックを入れて「許可」します。**
3. **`adb devices` で、端末が `device` と表示されることを確かめます**(`unauthorized` なら 2 の許可がまだです)。
   ```
   List of devices attached
   R5CT1234ABC    device
   ```
4. **画面ロックを「なし」にする**: PIN やパターンのロックは adb から解除できません。画面消灯までの時間も十分長くします。
   fleetest は実行の前とシナリオごとに画面を点けてロック画面を閉じますが、PIN やパターンは解けません。

- fleetest は、テストを安定させるために端末の設定を変えます(アニメーションのオフ、クラッシュ・ANR のダイアログを出さない など)。
  **実機ではこの変更が残ります**。戻すときは開発者向けオプションで戻してください。
- Play Protect の「アプリをセキュリティ確認のために送信しますか?」は、インストールの間だけ確認を切って通します。
  アプリが Google へ送られることはありません([installApp](../reference/commands/install_app_ja.md))。
- Wi-Fi で adb 接続した端末も、`adb devices` に `device` で出ていれば、表示された識別子(`192.168.1.23:5555` など)を
  そのまま使えます。

### 3. 実機用のアプリを用意する

いつもの APK をそのまま使えます。release 署名の APK も入れられます。

## 4. 実行プロファイルに入れる

### VSCode 拡張で入れる

1. デバイスモニターの「プロファイル」タブで実行プロファイルを開き、「デバイスを追加」の「+」を押します。
2. 「デバイスを選択」の一覧に、**つながっている実機**が並びます(iOS は「機種 / 接続経路 / UDID」の形)。
   ランナー機につないだ実機なら、上部の「マシン:」でそのマシンを選びます。
3. 使う実機にチェックを入れて「OK」を押します。

### 手で書く

実行プロファイルの `devices` に、`"kind": "physical"` と端末の識別子を書きます。

```jsonc
{ "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 15", "kind": "physical",
      "udid": "00008130-000A1B2C3D4E5678" },
    { "platform": "android", "machine": "local", "name": "Galaxy S24", "kind": "physical",
      "serial": "R5CT1234ABC" } ] }
```

- **iOS の `udid`** は、`xcrun devicectl list devices` の詳細(`hardwareProperties.udid`)にある `00008130-…` の形の値です。
  同じ一覧の Identifier 列(`XXXXXXXX-XXXX-…` の形)は別の値なので、使えません。
- **Android の `serial`** は、`adb devices` の左の列です。
- つながっている実機と識別子は、`fleetest api installed-devices` でも一覧できます(`ios.physicalDevices` / `android.physicalDevices`)。
- `machine` は、実機をつないだ Mac のマシン名です(手元なら `"local"`)。

## 5. 動かしてみる

```bash
fleetest run --profile <実行プロファイル> --scenario <シナリオID>
```

デバイスモニターでは、実機のタイルに「実機」のバッジが付きます。右クリックの「ブリッジを起動」で、テストを
流さずにブリッジだけを起動することもできます。

### iOS の初回の許可

最初にブリッジを起動するとき、端末に次の確認が順に出ます。**端末のロックを解除し、画面を見ながら**許可してください。

1. **開発元の証明書を信頼する**: 設定 → 一般 → VPN とデバイス管理 で、デベロッパ App の証明書を「信頼」します。
   証明書を作り直したときは、もう一度必要です。
2. **UI オートメーションを許可する**: ブリッジの起動中に、Touch ID / パスコードの確認が出ます。認証してください。
   出ないまま `Timed out while enabling automation mode` で止まるときは、設定 → デベロッパ → UI オートメーション が
   ON になっているかを確かめ、端末を再起動してからもう一度起動します。
3. **ローカルネットワークの許可**: 「ローカルネットワーク上のデバイスを見つけることを許可しますか?」が出たら「許可」します。

- **端末をチームに登録した直後の1回は、署名に失敗することがあります**。もう一度起動すれば通ります。
- 無料の Personal Team で署名した場合、署名は約7日で切れます。続けて使う Mac では、Apple Developer Program のチームで署名してください。

## ランナー機に実機をつなぐとき

ランナー機につないだ実機も、上と同じ手順で使えます。**ステップ1と2は、ランナー機の上で行います**
(ランナー機の前に座るか、画面共有で)。そのうえで、iOS では次の3つが加わります。

1. **Xcode へのサインインは、ランナー機の画面で行います。** SSH からはできません。
   `developmentTeam` と `bundleIDPrefix` も、ランナー機の `~/.config/fleetest/config.json` に書きます。
2. **端末をチームに登録するために、ランナー機の画面から1回実行します。** 登録には Apple との通信が要り、SSH からはできません。
   画面共有でランナー機のターミナルを開き、その実機を使うテストを1回実行してください(1回目は署名に失敗することがあります。
   もう一度実行すれば通ります)。端末を別のものに替えたときも、もう一度必要です。
   ```bash
   cd ~/fleetest-runner/users/<あなたの issuerId>/work
   ~/fleetest-runner/foundation-tester/.build/debug/fleetest run --profile <実行プロファイル> --scenario <シナリオID>
   ```
3. **署名の鍵を、SSH からでも使えるキーチェーンに置きます。** SSH の接続はキーチェーンがロックされた状態で始まり、
   画面で解錠しても引き継がれません。fleetest はビルドの前にキーチェーンを空のパスワードで解錠しようとするので、
   署名の鍵をパスワードの無い専用のキーチェーンへ移し、検索リストに載せます(ランナー機で実行します)。
   ```bash
   KC=~/Library/Keychains/fleetest-signing.keychain-db
   security create-keychain -p "" "$KC"
   # ログインキーチェーンから「Apple Development」の署名 ID を security export / import で移す
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC"
   security set-keychain-settings "$KC"            # 引数なし = 自動ロックしない
   security list-keychains -d user -s "$KC" ~/Library/Keychains/login.keychain-db
   ```
   移すのは開発用(Apple Development)の署名 ID だけにしてください。この運用が許されない場合は、実機を使う
   テストをランナー機の画面(画面共有)から実行します。

- Wi-Fi でつないだ iPhone を使うときは、ランナー機と端末が同じサブネットにいて、アクセスポイントのクライアント隔離
  (プライバシーセパレータ)が切ってある必要があります。関係するのはランナー機の側の LAN で、手元の Mac は関係しません。
- 実機を使うランナー機にも `brew install libimobiledevice` を入れてください。

## 実機で違うこと

| 機能 | iOS 実機 | Android 実機 |
|---|---|---|
| 写真・動画を入れる(`addMedia`) | できません。Simulator で実行するか、端末へ手で入れます | できます |
| アプリのデータを消す(`clearAppData`) | アプリを入れ直して消します。許可した権限も消えます。`appPathPhysical` が要ります | できます |
| 録画 | 操作の前後に撮った画面のコマ送りになります(撮影1回に約 50ms) | ふつうに録画します |
| エンジン | 常に XCUITest です(in-app は使えません) | — |
| 端末の設定 | 自動ロックを「なし」にします | 画面ロックを「なし」に。fleetest が変えた設定は残ります |
| 押すボタンの無いシステムアラート | 残ることがあります(Simulator のように起こし直せません) | — |
| Safari の中の要素を読む | 端末で 設定 → Safari → 詳細 → Web インスペクタ を ON にします | — |

## うまくいかないとき

| メッセージ・症状 | 原因と対処 |
|---|---|
| `requires an Apple Developer Team ID` | `developmentTeam` が未設定です(iOS のステップ1の3) |
| `Cannot code-sign the bridge runner for a physical device` | 署名の設定が足りません。続く `Detected:` に、欠けているもの(Xcode のアカウント・チーム・証明書・端末の登録 など)が出ます |
| `No Account for Team` | Xcode に、`developmentTeam` のチームのアカウントがありません。Team ID の取り違え(`security find-identity` の括弧の値を書いた)も、これになります |
| `the keychain holding the signing key is locked` | ランナー機で、SSH から署名の鍵を使えません(「ランナー機に実機をつなぐとき」の3) |
| `Developer Mode is off on the device` | デベロッパモードを ON にします(iOS のステップ2) |
| `Developer App Certificate is not trusted` | 設定 → 一般 → VPN とデバイス管理 で証明書を信頼します |
| `Timed out while enabling automation mode` | 端末のロックを解除し、出てくる確認で認証してからもう一度起動します。出ないときは 設定 → デベロッパ → UI オートメーション を確かめ、端末を再起動します |
| `the iPhone is locked` | 端末のロックを解除し、自動ロックを「なし」にします |
| `no physical iOS device with that UDID` | USB の接続・「このコンピュータを信頼」・デベロッパモードを確かめます。`udid` に Identifier 列の値を書いていないかも確かめます |
| `Failed to read socket ID from device` | 端末の中でアプリの起動が詰まっています。端末を手で再起動してください |
| `The executable contains an invalid signature` | Simulator 向けのビルドを入れようとしています。`appPathPhysical` に実機向けのビルドを書きます |
| `is not visible to adb` | Android の USB の接続と、USB デバッグの許可を確かめます。`adb devices` で `device` になっている必要があります |
| `could not unlock the lock screen` | Android の画面ロックを「なし」にします |
| `Connection to the driver was refused`(iPhone) | Wi-Fi(LAN)経由のときに起きやすい、途中での切断です。`brew install libimobiledevice` を入れて USB 経由にし、`fleetest bridge down --port <ポート>` で起動し直します |

### Link
- [index](../index_ja.md)
