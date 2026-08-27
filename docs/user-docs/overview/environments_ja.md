# 必要環境

## 対応環境

| 対象 | 要件 |
|---|---|
| 共通 | macOS 26+ |
| iOS をテストするなら | Xcode 26+、iOS シミュレータ、[xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`) |
| Android をテストするなら | Android SDK(adb)、エミュレータまたは実機 |
| 拡張ビルド | Node.js v24 以降、npm v11 以降 |

iOS と Android を両方揃える必要はありません。テストする側だけ用意すれば動きます。

このマシンで何が使えるかは `fleetest doctor` がまとめて確認します —— Foundation Models・
Xcode・xcodegen・シミュレータ・adb。

## Apple Intelligence(任意)

Apple Intelligence(Foundation Models)は無くても動きますが、有効にすると次の3つが使えます。
後から有効化しても、そのまま使えるようになります。

- **自己修復** —— セレクタが壊れたときにモデルが修復し、シナリオを続行させます。修復結果は
  キャッシュされ、2回目以降の実行ではモデルを呼びません。
- **`screenLooksLike`** —— 画面と自然文の説明を照合する視覚検証です。
- **失敗時のトリアージ** —— 失敗原因の要約と修正案をレポートに残します。

処理はすべてオンデバイスで、アプリの画面情報が Mac の外に出ることはありません。

### 制限

- **現時点では英語のみです。** Apple のオンデバイスモデルは 2026 年内は日本語に対応せず、
  日本語サポートは 2027 年の見込みです。使うには **Mac のシステム言語を英語(United States)に
  する必要があり**、`screenLooksLike` の説明文も英語で書きます。日本語 UI のアプリに対する
  挙動は、この間は保証できません。
- macOS 26 では視覚検証(`screenLooksLike` と偽陽性チェック)だけが使えません。画像入力が
  macOS 27+ 必須のためで、自動で無効になり、他の機能は制限なく動きます。
- FM が使えない環境では、これらの機能は失敗ではなく**スキップ**されます。run は緑のまま、
  機能だけが黙って無効になるので、実際に使えているかは `fleetest doctor --fm-only` で確認して
  ください。1回実際に推論して判定します。詳細は
  [トラブルシューティング](../in_action/troubleshooting_ja.md)。

## 動作確認している UI フレームワーク

| フレームワーク | 対象 OS |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS、Android |
| Flutter | iOS、Android |
| React Native | iOS、Android |
| View/XML | Android |

### Link
- [index](../index_ja.md)
