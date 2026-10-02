# アンインストール

Fleetest のアンインストールの手順です。

## AIアシスタントに依頼する

AIアシスタントに次のように頼むと、下の手順をまとめて行います。

```text
../foundation-tester/docs/user-docs/uninstall_ja.md の手順で fleetest をアンインストールして。
```

## VSCode 拡張

VSCode の拡張ビューからアンインストールします。

## 作業フォルダ

VSCode を終了してから Finder や `rm` で削除します。

## 残るファイルとプロセス

fleetest のプロセスを止めてから(下のコマンド)、次のものも削除します。

- fleetest のクローン(既定では作業フォルダの隣の `foundation-tester`。ビルドフォルダを含めて数 GB あります)
- `~/.fleetest`(この Mac での実行の記録など)と `~/Library/Logs/fleetest`(ログ)
- 必要なら `~/.config/fleetest/config.json`
- fleetest のために作った仮想デバイスが不要なら、Xcode の「Devices and Simulators」や Android Studio の
  Device Manager から削除します

作業フォルダを削除しても `.build` が復活する場合は、fleetest のプロセスが残っています。

```bash
pgrep -fl 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
pkill  -f 'fleetest-mcp|/fleetest (api|run|bridge|devices)|fleetest-(simstream|androidstream|devicepoll)|xcodebuild.*FleetestRunner'
```

### Link
- [index](index_ja.md)
