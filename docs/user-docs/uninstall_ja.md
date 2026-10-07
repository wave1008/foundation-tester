# アンインストール

[in English](uninstall.md)

Fleetest のアンインストールの手順です。

## AIアシスタントに依頼する

AIアシスタントに次のように頼むと、下の手順をまとめて行います。

```text
../foundation-tester/docs/user-docs/uninstall_ja.md の手順で fleetest をアンインストールして。
```

## 0. ランナー機(使っている場合)

リモートのランナー機を使っているときは、手元の fleetest を消す前に、ランナー機の作業場所を消します。

```bash
../foundation-tester/.build/debug/fleetest remote teardown <マシン名>
```

iOS 実機のために、ランナー機に署名用のキーチェーンを作った場合は、ランナー機でそれも消します
(署名の鍵が入っています)。

```bash
security delete-keychain ~/Library/Keychains/fleetest-signing.keychain-db
```

## 1. VSCode 拡張

VSCode の拡張ビューからアンインストールし、`Developer: Reload Window` を実行して拡張を止めます
(拡張が動いている間は、止めた fleetest のプロセスを拡張が起動し直します)。

## 2. fleetest のプロセスを止める

この Mac で動いている fleetest のプロセスを、作業フォルダに関係なくすべて止めます(他の作業フォルダで
使っている fleetest も止まります)。

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

## 3. 作業フォルダとクローン

VSCode を終了してから、作業フォルダと fleetest のクローン(既定では作業フォルダの隣の `foundation-tester`。
ビルドフォルダを含めて数 GB あります)を Finder や `rm` で削除します。
削除しても `.build` が復活する場合は、fleetest のプロセスが残っています(手順2)。

## 4. 残るファイル

- `~/.fleetest`(この Mac での実行の記録など)・`~/Library/Logs/fleetest`(ログ)・`~/Library/Caches/fleetest`
- `~/.config/fleetest/`(設定と、この Mac だけのテストデータ)。**`dataset/` にパスワードなどの秘密を置いているなら、
  必ず消します**
- fleetest のために作った仮想デバイスが不要なら、Xcode の「Devices and Simulators」や Android Studio の
  Device Manager から削除します

## 5. AIアシスタントの MCP 登録

Claude Code の登録(`.mcp.json`)は作業フォルダと一緒に消えます。Codex など、AIアシスタント自身の設定に
登録した場合は、その登録も削除します。Codex なら次のコマンドです。

```bash
codex mcp remove fleetest
```

### Link
- [index](index_ja.md)
