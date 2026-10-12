# SUT の UI フレームワークの版を上げる手順

fleetest 自身の SUT(E2E・E2EX・E2EY)の Flutter・React Native・Compose Multiplatform を最新の安定版へ
上げるときの手順と、2026-10-13 に Flutter 3.44.7 → 3.47.7・RN 0.86.2 → 0.87.1 を上げたときに踏んだ罠。
**受け手が作るアプリは新しい版で作られる**ので、SUT が古いままだと受け手が最初に踏む不具合を先に見つけられない。

## 0. 範囲と前提

| フレームワーク | SUT(3系統とも同じ版に揃える) | 版の宣言 |
|---|---|---|
| Flutter | `E2EAppFlutter/` `E2EXAppFlutter/` `E2EYAppFlutter/` | 各機械の Flutter SDK(リポジトリに版の固定は無い)+ `pubspec.lock` |
| React Native | `E2EAppRN/` `E2EXAppRN/` `E2EYAppRN/` | `package.json` / `package-lock.json` / `ios/Podfile.lock` / `android/` のひな形 |
| Compose Multiplatform | `E2EAppCMP/` `E2EXAppCMP/` `E2EYAppCMP/` | `gradle/libs.versions.toml`(`composeMultiplatform` / `kotlin` / `agp`) |

- **SUT をビルドする機械**: E2E・E2EY は手元(M2Ultra)、E2EX は M1Ultra(`Scripts/e2ex.sh --on M1Ultra` が向こうのクローンで
  SUT をビルドする。`dist/` は gitignore なのでアラインでは届かない)。**フレームワークの SDK・ツールは両方の機械に要る**
- 追うのは**最新の安定版だけ**(旧版を並べて検証しない。ユーザー決定 2026-10-08)
- **1フレームワークずつ**上げてコミットを分ける(赤の帰属を1つに絞る)

## 1. 最新の安定版を確かめる(着手のたびに)

```bash
# Flutter(stable の現行)
curl -s https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);h=d["current_release"]["stable"];print([r["version"] for r in d["releases"] if r["hash"]==h][0])'
# React Native と、それが求める React / Node
npm view react-native@latest version peerDependencies engines --json
# Compose Multiplatform / Kotlin(maven-metadata の <release> は alpha・Beta を含むので数字だけで最大を取る)
for u in org/jetbrains/compose/compose-gradle-plugin org/jetbrains/kotlin/kotlin-gradle-plugin; do
  curl -s https://repo1.maven.org/maven2/$u/maven-metadata.xml | grep -oE '<version>[0-9.]+</version>' | sed 's/<[^>]*>//g' | sort -V | tail -1; done
```

## 2. 共通の流れ

1. **各機械の SDK・ツールを揃える**(下の各節)。`fleetest remote machines` の全機のうち、SUT をビルドする機械は必ず
2. **SUT を書き換える**(3系統とも)
3. **コミット → `Scripts/align.sh`**(アラインは指示を受けてから)。**未コミットのまま M1Ultra でビルドしない** ——
   ビルドがランナーのクローンの追跡ファイル(lock 等)を書き換えると、次のアラインが止まる
4. **回す**(全体の実行なので `FT_FULL_TEST=1` が要る = ユーザーに全実施の了承を取ってから):

   ```bash
   FT_FULL_TEST=1 Scripts/e2e.sh  --local --<fw>                  # iOS in-app + Android + 陽性対照
   FT_FULL_TEST=1 Scripts/e2e.sh  --local --<fw> --ios-xcuitest
   FT_FULL_TEST=1 Scripts/e2ey.sh --<fw>
   FT_FULL_TEST=1 Scripts/e2ey.sh --<fw> --ios-xcuitest
   FT_FULL_TEST=1 Scripts/e2ex.sh --on M1Ultra --<fw>             # 手元の E2E と同時に起こしてよい
   FT_FULL_TEST=1 Scripts/e2ex.sh --on M1Ultra --<fw> --ios-xcuitest
   ```
   `<fw>` は `flutter` / `rn` / `cmp`。e2ex は手元の ssh が切れると向こうも止まる(**手元の Mac を再起動しない**)
5. **FM の状態を数える**: 各 run の結果 JSON の `fm.calls` / `fm.skipped`。FM が止まっていた回は「FM を飛ばした
   ステップが 0 か」を見る(0 なら判定に影響なし)。止まりかたは下の「FM」
6. **赤は版を上げる前の結果と突き合わせる**(同じシナリオの過去の結果。`results/runs/*/scenarios/*.json` の `passed`。
   ファイル名は NFD なので照合前に NFC へ正規化する)。前からある間欠の赤は回し直しで確かめる
7. **受け手向け docs の「確かめた環境」を直す**: `docs/user-docs/reference/writing/ui_component_patterns.md` と `_ja.md`(対で)

### SUT の作り直しは自動(2026-10-13 から)

- `Scripts/sut-rebuild.sh`(e2e.sh / e2ex.sh / e2ey.sh / e2e-devices.sh が共有)が、**ソースの mtime** に加えて
  **成果物を作ったときの SDK の版**(Flutter の revision・iOS は Xcode のビルド番号。成果物の隣の `<成果物>.sdk`)を
  見て作り直す。版の宣言のファイル(lock・`libs.versions.toml`・`gradle-wrapper.properties` 等)も監視している
- RN のビルドスクリプトは `Scripts/rn-deps.sh` で、ビルドの前に `node_modules`・`Pods` を lock に揃える
  (`npm ci` / `pod install --deployment` = lock を書き換えない)
- **これより前は SDK だけ上げても作り直さず、古い版のアプリのまま黙って緑になった**(M1Ultra の E2EX-Flutter で
  踏んだ)。作り直しの判定が怪しいときは `--rebuild` を付ける

## 3. Flutter

1. **SDK を上げる**(機械ごとに入れ方が違う):
   - 手元(M2Ultra): Homebrew の cask → `brew upgrade --cask flutter`
   - M1Ultra・M1Max: `~/flutter` の git チェックアウト → `git -C ~/flutter fetch --tags && git -C ~/flutter checkout <版> && flutter --version`
     (`channel [user-branch]` と出るのはタグの detached。前からこの形)
   - M1mini には Flutter が入っていない(SUT をビルドしない)
   - **上げたら全機の Framework の revision が一致しているか**を `flutter --version` で見る
2. **各 SUT で `flutter pub get`**(3系統とも)。`pubspec.lock` の推移的な依存と、Flutter のツールが足す
   `analysis_options.yaml` の `analyzer.exclude` が変わる → これをコミットする
3. 回す(2. の 4)

## 4. React Native

1. **Node の条件**を `npm view react-native@<版> engines` で見る。0.87 は `^22.13.0 || ^24.3.0 || >= 26`
   - M1Ultra の Node は公式インストーラの `/usr/local/bin/node`(root の下・sudo が要る)なので、Homebrew の
     `node@22` を入れて `brew link --overwrite --force node@22`(`/opt/homebrew/bin` が PATH で前に来る)。2026-10-13 に v22.23.3
2. **Android SDK**: ひな形の `compileSdkVersion` / `buildToolsVersion` を全機に入れる
   (`~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-37.0" "build-tools;37.0.0"`。
   名前は `android-37` ではなく `android-37.0`)
3. **公式のひな形の差分を当てる**(rn-diff-purge。バイナリの gradle-wrapper.jar も含む):

   ```bash
   curl -sfL https://raw.githubusercontent.com/react-native-community/rn-diff-purge/diffs/diffs/<旧>..<新>.diff -o template.diff
   git apply --check -p2 --directory=E2EAppRN --exclude='*/package.json' template.diff   # 3系統とも --check してから
   ```
   `package.json` は SUT ごとに依存が違うので差分では当てない(次で npm)。`tsconfig.json` は SUT ごとに当たるかを見る
4. **`package.json` の RN 本体と仲間(`react-native`・`@react-native/*`・`@react-native-community/cli*`・ひな形の
   `typescript`)を一度に書き換えてから `npm install` を1回**。分けて打つと途中の状態で ERESOLVE になる
   - **古い lock の上では ERESOLVE で解けないことがある**(2026-10-13 の E2EX・E2EY。lock に無い制約は見当たらない)。
     そのときは lock をゼロから解き直す(一時ディレクトリで `npm install --package-lock-only` → 写して `npm ci`)。
     **RN 以外のライブラリも `^` の範囲で上がる**ので、上がった直接の依存をコミットに書く
   - サードパーティのうち RN の版を範囲で縛るもの(reanimated・worklets の `0.86 - 0.88` 等)は、
     `package-lock.json` の `peerDependencies.react-native` を走査して確かめる
5. **Pods**: `pod install`。**`Pods/Local Podspecs`(外部パスの podspec の前回の写し)が残っていると壊れる**:
   - `React-Core-prebuilt` だけ前の版のまま残る(`Podfile.lock` に旧版が残る)→ 0.87 ではヘッダの置き方が変わり
     `React-Core-prebuilt/Headers/module.modulemap not found` でビルドが落ちる
   - `pod install --deployment` が hermes-engine で「版が変わった」と止まる
   - 直し: `pod update React-Core-prebuilt`、または `ios/Pods/Local Podspecs` を消してから `pod install`。
     **`Podfile.lock` に旧版の RN の pod が残っていないか** `grep -E '\(<旧版>\)' ios/Podfile.lock` で確かめる。
     `Scripts/rn-deps.sh` は入れ直しの前に `Local Podspecs` を消す(リモートはこれで通る)
   - `pod install` が `PrivacyInfo.xcprivacy` の並びを入れ替えることがある → そのままコミットする(残すと次の
     `pod install` のたびに作業ツリーが汚れる)
6. ひな形で挙動が変わる設定に注意: 0.87 は `edgeToEdgeEnabled=true`(Android で画面がシステムバーの下まで描かれる)。
   2026-10-13 時点では赤は出ていない
7. **lock を解き直すと RN 以外も上がる → 上がったライブラリで SUT が壊れていないかを赤から疑う**。2026-10-13: reanimated
   4.7.0 → 4.7.1 で、RN 0.87.1 と組むと E2EY-RN の react-native-collapsible-tab-view が iOS で動かなくなった(上端まで戻しても
   ヘッダが開かない・ページを払ってもタブが替わらない。指で直接ドラッグしても動かない = ツールではなくアプリ)。
   reanimated だけ 4.7.0 に戻すと3本とも緑 → **E2EYAppRN は `react-native-reanimated` を `4.7.0` ちょうどに固定**
   (`^` に戻すと解き直しでまた 4.7.1 になる)。新しい reanimated / collapsible-tab-view が出たら外せるか試す

## 5. Compose Multiplatform(2026-10-13 時点で未実施)

- `gradle/libs.versions.toml` の `composeMultiplatform` と `kotlin` を3系統とも書き換える(作り直しは監視が拾う)
- **AGP はメジャーを跨ぐ更新(8 → 9)を同時にしない**のが案(9 はビルドの書き方に非互換がある。RN のひな形も
  `android.builtInKotlin=false` / `android.newDsl=false` で AGP 9 の振る舞いを止めている)。CMP の新版が AGP 9 を
  必須にしているかを着手時に確かめる
- Kotlin・Compose の互換表(Compose Multiplatform のリリースノート)で Kotlin の版の組み合わせを確かめる

## 6. 実行中に起きたこと

### FM が ANE の「no memory」で止まる

- 2026-10-13 に M2Ultra で2回(04:21・04:38)、M1Ultra では再起動から約20分後(05:04)に、E2E の実行中に止まった
  (`fleetest doctor --fm-only` の実呼び出しが text・vision とも失敗。`/usr/bin/log show` に
  `appleneuralengine Code=53 … Program load failed`)。M2Ultra は数分でひとりでに戻ったこともある
- **Bash ツールの zsh では `log` が組み込みに取られる** → `/usr/bin/log show` と書く(素の `log show` は何も返さない)
- その回で FM を呼ぶ場面が無ければ判定に影響しない(結果 JSON の `fm.skipped` が 0)。2026-10-13 の Flutter / RN の全実行で
  FM の呼び出しは1回の全体実行で 0〜4 回、飛ばしたステップは 0 だった

### 赤の見分け

- 2026-10-13 の E2EY-Flutter の Android の赤2本(引き伸ばせるシート S0020・入れ子の横の一覧 S0010)は、版を上げる前
  (10/5)にも同じ赤があり、回し直しで 10/10 緑 = 前からある間欠の赤。8台並列の負荷での頻度は未測定

## 7. 2026-10-13 の結果(基準)

| SUT | 機械 | iOS in-app | Android | iOS XCUITest |
|---|---|---|---|---|
| E2E-Flutter(3.47.7) | M2Ultra | 47/47 | 47/47 | 47/47 |
| E2EY-Flutter(3.47.7) | M2Ultra | 33/33 | 31/33(間欠の2本) | 33/33 |
| E2EX-Flutter(3.47.7) | M1Ultra | 48/48 | 49/49 | 48/48 |
| E2E-RN(0.87.1) | M2Ultra | 48/48 | 48/48 | 48/48 |
