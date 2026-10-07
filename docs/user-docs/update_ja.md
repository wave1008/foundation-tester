# 更新

[in English](update.md)

fleetest の更新の手順です。

更新があると、VSCode 拡張が起動時に通知します(1日1回まで)。

## AIアシスタントに依頼する

AIアシスタントに「fleetest を更新して」と頼むと更新できます。

> ログは `<作業フォルダ>/.fleetest/install-*.log` に残ります。

## VSCode から更新する

デバイスモニターの「設定」タブで確認と実行ができます。

## 手で更新する

作業フォルダ(`TestProjects/` があるフォルダ)で、fleetest のクローンにある更新スクリプトを実行します。

```bash
bash ../foundation-tester/Scripts/update.sh
```

- 更新が無ければ「Up to date」と表示して何もせずに終わります。壊れた導入を入れ直したいときだけ `--force` を付けます。
- クローンが作業フォルダの隣の `foundation-tester` ではないときは `--tool-root <クローンのパス>`、作業フォルダが
  カレントでないときは `--work-dir <作業フォルダ>` を付けます。
- fleetest 本体の取得・ビルド・VSCode 拡張の入れ直し・テストプロジェクトの再整合まで、まとめて行います。

## 更新したあとにすること

- **VSCode を再読み込みする**: コマンドパレットで `Developer: Reload Window` を実行します。拡張が新しい版に入れ替わるのは
  再読み込みのあとです。AIアシスタントも再起動すると、新しい手順書が読まれます。
- **ランナー機も同じ版に揃える**: リモート実行を使っているときは、ランナー機も手元と同じ版にします。揃っていないと
  テストは始まりません。手順は[Mac を追加する](fleet/adding_mac_ja.md)の「fleetest を更新したとき」にあります。

## 閉域網で更新する

インターネットに出られない環境では、更新も `bash <クローン>/Scripts/update.sh` を直接実行します
(`curl` で取る形は使えません)。GitHub 宛てを社内ミラーへ向ける設定は
[ネットワークの露出とセキュリティ](security/network_security_ja.md)にあります。

### Link
- [index](index_ja.md)
