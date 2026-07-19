---
name: ftester-update
description: 既に foundation-tester をセットアップ済みの受け手が、新しい修正版（upstream の更新）を取り込む。git pull → Projects/ と Package.swift の再整合 → 再ビルド → VSCode 拡張の再インストール → 反映（Reload Window）までを検証付きで実行する。「更新して」「最新にして」「アップデートして」「新しい版を取り込んで」等の依頼で使う。初回セットアップは /ftester-setup。
---

# ftester 更新 runbook

セットアップ済みの環境に upstream の修正版を取り込む。初回導入は `/ftester-setup`。
背景・手動手順は docs/getting-started.md の「更新のしかた」。

## 進め方の原則

- 各ステップは **exit code で成否判定**（パイプで grep に繋がない）。
- **人間チェックポイント（🧑）では停止**する（Reload Window はエージェントでは代行不可）。
- 受け手の資産（`Projects/<自分のプロジェクト>/`）を壊さない。`git pull` が衝突したら
  勝手に解決せず、状況をそのままユーザーに見せて相談する。

## 手順

### 1. 取り込み

リポジトリルートで:

```
git pull
```

- 衝突が出たら停止して報告する。受け手の `Projects/` が git 管理下にあると衝突しやすい
  （getting-started.md は Projects/ を管理外/別リポジトリにすることを推奨している）。

### 2. Projects/ ↔ Package.swift の再整合

```
swift run ftester project sync
```

upstream 側でプロジェクト構成が変わっても、マーカー区間を再生成して整合させる。

### 3. 再ビルド

```
swift build
```

- 🧑 **macOS/Xcode のベータ世代が変わっていた場合**は、Xcode を同じベータへ揃えてから
  フルリビルドが必要（FoundationModels の ABI 不整合で全バイナリが dyld クラッシュする）。
  クラッシュや dyld エラーが出たらこれを疑い、ユーザーに確認する。

### 4. 環境検証

```
swift run ftester doctor
```

赤が出たら対処してから次へ。

### 5. VSCode 拡張の再インストール

```
cd vscode-ftester && npm install && npm run install-local
```

`install-local` はパッケージ→インストール→到達確認まで一括。**exit code で成否判定**。

### 6. 🧑 人間チェックポイント（反映）

ユーザーに依頼する（代行不可）:

- VSCode で `Developer: Reload Window`（インストールだけでは旧版のまま動く）
- デバイスモニター等のパネルは**開き直す**（retainContextWhenHidden で古い HTML が残るため）

### 7. 動作確認

最小の1本を通して回帰がないことを確認する:

```
swift run ftester run --project <ProjectName> --profile ios
```
