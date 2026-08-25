# ft_e2e_rn

fleetest の E2E テスト対象アプリ(SUT)。React Native 0.86(New Architecture 有効) + TypeScript。

UI 契約(`#id`・ラベル・画面構成)の唯一の正は `E2EAppCMP/docs/ui-contract.md`。
シナリオは `TestProjects/E2E-RN/scenarios` を参照。

## ビルド

```sh
scripts/build-ios.sh      # dist/ios-simulator/FTE2ERN.app (Release)
scripts/build-android.sh  # dist/android/ft-e2e-rn-release.apk (Release)
```

いずれも初回は `bundle exec pod install`(iOS)/ `npm install` が別途必要。
