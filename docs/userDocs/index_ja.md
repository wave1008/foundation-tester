# fleetest mobile ドキュメント

[in English](index.md)

fleetest は macOS 上で動く iOS / Android アプリの E2E テストツールです。シナリオは Shirates 風の
Swift DSL で書き、LLM なしで決定的に再生します。Foundation Models(オンデバイス)が介入するのは
ステップが失敗したときだけです。テストは Claude Code(MCP)に作らせる・VSCode 拡張で録画する・
手書きする、の3通りで作れ、どれも同じ `.swift` シナリオになります。

## リポジトリ

- [foundation-tester](https://github.com/wave1008/foundation-tester)

## 概要

- [fleetest とは](overview/about_ja.md)
- [動作環境](overview/environments_ja.md)
- [はじめに(インストール)](getting-started_ja.md)
- [クイックスタート](quick-start_ja.md)
- [Shirates 利用者向けの対応表](overview/for_shirates_users_ja.md)

## チュートリアル(Basic)

### プロジェクトの作成

- [テストプロジェクトの作成](project/creating_project_ja.md)
- [プロファイル(アプリ / マシン / 実行)](project/profiles_ja.md)
- [実行プロファイルの設定項目](project/run_profile_ja.md)

### テストクラスの作成

- [テストクラスの作成](testclass/creating_testclass_ja.md)
- [要素の選択と検証](testclass/select_and_assert_ja.md)
- [テストコードの構造](testclass/testcode_structure_ja.md)
- [テスト結果ファイル](testclass/test_result_files_ja.md)

### セレクタ

- [セレクタ式](selector/selector_expression_ja.md)
- [相対セレクタとスコープ](selector/relative_selector_ja.md)
- [型付きセレクタ(Sel)](selector/typed_selector_ja.md)
- [WebView 内の要素](selector/webview_ja.md)

### 関数/プロパティ

- 要素のタップ
    - [tap, tapWithScroll*, tapWithoutScroll, tapAppIcon](commands/tap_ja.md)
- 要素の選択
    - [select, selectWithScroll*, lastElement](commands/select_ja.md)
- アプリのインストールと起動
    - [installApp, removeApp, clearAppData](commands/install_app_ja.md)
    - [launchApp, restartApp, terminateApp, openURL](commands/launch_app_ja.md)
- ナビゲーション
    - [home, back, appSwitcher, rotateTo](commands/navigation_ja.md)
- 画面のスワイプ/スクロール
    - [swipe, swipePointToPoint, swipeElementToElement, swipeBy](commands/swipe_ja.md)
    - [スクロール(scrollTo, scrollDown, withScrollDown, scrollFrame, …)](commands/scroll_ja.md)
    - [flick](commands/flick_ja.md)
    - [マップ・キャンバス系のジェスチャ(doubleTap, pinchIn, pinchOut)](commands/gestures_ja.md)
- 編集とキーボード操作
    - [type](commands/type_ja.md)
    - [clearInput](commands/clear_input_ja.md)
    - [pressEnter, hideKeyboard](commands/press_enter_hide_keyboard_ja.md)
- 存在の検証
    - [exist, notExist, countIs](commands/existence_assertion_ja.md)
- 属性の検証
    - [テキストの検証(textIs, textContains, …)](commands/text_assertion_ja.md)
    - [値の検証(valueIs, valueContains, …)](commands/value_assertion_ja.md)
    - [id の検証(idIs)](commands/id_assertion_ja.md)
    - [状態の検証(enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF)](commands/state_assertion_ja.md)
- その他の検証
    - [キーボードの検証(keyboardIsShown, keyboardIsNotShown)](commands/keyboard_assertion_ja.md)
    - [画面の検証(screenLooksLike)](commands/screen_assertion_ja.md)
    - [アプリの検証(appIs)](commands/app_assertion_ja.md)
- 任意の値の検証
    - [任意の値の検証(thisIs, thisContains, …)](commands/any_value_assertion_ja.md)
- まとめて検証
    - [まとめて検証(verify)](commands/verify_ja.md)
- 値の読み出し
    - [掴んだ要素の値を読む(.text, .value, .id, lastElement)](commands/reading_values_ja.md)
- 分岐
    - [ifCanSelect, ios, android](commands/branch_ja.md)
- 反復
    - [repeatWhileCanSelect, doUntilTrue](commands/repeat_ja.md)
- 同期
    - [wait, waitForDisplay, waitForClose](commands/wait_ja.md)
- 記述子
    - [group, procedure, setUp, tearDown](commands/descriptors_ja.md)
- スクリーンショット
    - [screenshot](commands/screenshot_ja.md)
- イレギュラーの処理
    - [irregularHandler](commands/irregular_handler_ja.md)
    - [suppressHandler, useHandler, disableHandler, enableHandler](commands/suppress_handler_ja.md)
    - [iOS のシステムアラート(iosAlertHandler)](commands/ios_alert_handler_ja.md)

### 実行

- [シナリオの実行(fleetest run)](running/running_scenarios_ja.md)
- [dry-run(No-Load-Run)](running/dry_run_ja.md)
- [自己修復とヒールキャッシュ](running/self_healing_ja.md)
- [並列実行](running/parallel_execution_ja.md)
- [結果の分析(fleetest results・ダッシュボード)](running/results_analysis_ja.md)

### ツール

- [VSCode 拡張](tools/vscode_extension_ja.md)
- [MCP サーバ(Claude Code)](tools/mcp_server_ja.md)
- [Claude Code のスキル](tools/claude_code_skills_ja.md)

## チュートリアル(In action)

- [壊れにくいシナリオの書き方](in_action/writing_robust_scenarios_ja.md)
- [CI で回す](in_action/ci_ja.md)
- [リモートランナー](in_action/remote_runners_ja.md)
- [トラブルシューティング](in_action/troubleshooting_ja.md)

## リファレンス

- [DSL コマンドリファレンス](../commands.md)
- [結果 JSON のスキーマ](../results-json.md)
