# AndroidRunner — ftester Android ブリッジ

iOS の `Runner/`(XCUITest ランナー)と対になる、Android デバイス常駐の HTTP サーバ。
uiautomator dump(約2秒)の代わりに AccessibilityNodeInfo を直接走査して
スナップショットをミリ秒オーダーで返す。プロトコルは iOS ブリッジと完全互換
(`Sources/FTCore/BridgeDTO.swift` の 9 エンドポイント)なので、ホスト側は
`BridgeClient` をそのまま使う。

- 純フレームワーク API の Java のみ(androidx / gradle / Kotlin 不使用)
- `Sources/FTAndroid/AndroidBridge.swift` が初回操作時に自動インストール・自動起動する。
  手動セットアップは不要

## 仕組み

```
ホスト: BridgeClient → adb forward tcp:<自動割当> ⇄ デバイス: localhost:8123
                                                    BridgeInstrumentation(常駐)
```

- 起動: `adb shell "am instrument -w -e port 8123 com.example.ftbridge/.BridgeInstrumentation </dev/null >/dev/null 2>&1 &"`
  - **-w は必須**(UiAutomationConnection は am プロセス側に生成される)。
    デバイス内でバックグラウンド化するので adb 切断後も常駐する
- 停止: `adb shell am force-stop com.example.ftbridge`(`ftester bridge down --platform android`)
- 注意: ブリッジ稼働中は `uiautomator dump` が使えない(a11y 接続は実質1本。dump 側が
  Killed される)
- 整定待ち: `/tap` `/type` `/swipe` `/press` `/session` は操作注入後、対象パッケージ由来の
  a11y イベントが `QuietWaiter.QUIET_MS`(200ms)静まるまで待ってから応答する(ホスト側の
  固定 sleep の代替)。`setOnAccessibilityEventListener` ベースで busy-wait も HTTP/snapshot
  ポーリングもしない。上限は `QuietWaiter.ACTION_CAP_MS`(2s)/ launch は 10s

## ビルド

```bash
./build.sh            # prebuilt/ftbridge.apk を更新
./build.sh --install  # + 接続中の全デバイスへインストール
```

サーバコードを変更したら **build.sh の VERSION_CODE と
`Sources/FTAndroid/AndroidBridge.swift` の `expectedBridgeVersionCode` を同時に上げる**。
ホストは versionCode 不一致を検出すると自動で再インストールする。

## スナップショット変換の仕様

`SnapshotBuilder.java` は以下の変換を行う: フィルタ(可視性・サイズ)、
型語彙マップ(Android クラス名 → iOS 側と共通の型名)、リスト行のテキスト昇格、
ref 採番。dump との意味論合わせ: `isVisibleToUser()==false` のサブツリーは除外、
`isShowingHintText()==true` の text は空扱い。

## 実測(2026-07-08, emulator-5556, Android 16)

| 操作 | adb 直叩き | ブリッジ |
|---|---|---|
| snapshot(HTTP 素) | 約 2.0 秒(uiautomator dump) | **中央値 8.7ms**(10回、min 5.8/max 12.9) |
| snapshot(CLI 実効) | 約 2.2 秒 | 0.06〜0.14 秒 |
| 日本語 type | 1.2〜2.9 秒(ADBKeyboard IME 切替) | 0.74 秒(ACTION_SET_TEXT、IME 無変更) |
| フロー1本(3ステップ) | 11.0 秒 | 5.2 秒 |
| フロー8本一括 | 87.3 秒 | 38.0 秒(2.3倍) |

初回のみ自動セットアップ(APK インストール+起動+ready 待ち)で +約1.3 秒。
