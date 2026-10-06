# fleetest mobile ドキュメント

[in English](index.md)

fleetest は、Claude Code などの AIアシスタントに自然言語で頼んで使う、iOS / Android アプリの
E2E テストツールです。名前の由来と特徴は [Fleetest とは](overview/about_ja.md) を参照してください。

はじめての方は、[はじめに](getting-started_ja.md)でインストールし、[クイックスタート](quick-start_ja.md)、
[チュートリアル](#チュートリアル)の順に進んでください。

## リポジトリ

- [foundation-tester](https://github.com/wave1008/foundation-tester)

## 概要

- [fleetest とは](overview/about_ja.md)
- [環境](overview/environments_ja.md)
- [はじめに(インストール)](getting-started_ja.md)
- [クイックスタート](quick-start_ja.md)

## チュートリアル

- [AIアシスタントへの頼み方](tutorial/asking_ai_ja.md)
- [アプリとデバイスを用意する](tutorial/preparing_app_and_devices_ja.md)
- [テストを作る](tutorial/creating_tests_ja.md)
- [テストを実行する](tutorial/running_tests_ja.md)
- [結果を読み、失敗を調べる](tutorial/investigating_failures_ja.md)
- [アプリの変更にテストを追従させる](tutorial/keeping_up_with_app_changes_ja.md)
- [VSCode で見る](tutorial/watching_in_vscode_ja.md)

## 運用

- [更新](update_ja.md)
- [アンインストール](uninstall_ja.md)
- [CI で回す](in_action/ci_ja.md)
- [リモートランナー](in_action/remote_runners_ja.md)
- [リモートランナーのセットアップ](in_action/remote_runner_setup_ja.md)
- [ネットワークの露出とセキュリティ](in_action/network_security_ja.md)
- [トラブルシューティング](in_action/troubleshooting_ja.md)
- [長く使うためのメンテナンス](in_action/maintenance_ja.md)

## リファレンス

シナリオ(Swift DSL)・CLI・MCP の仕様です。AIアシスタントが書いたシナリオを読みたいとき、
自分で書き足したいときに参照してください。

### プロジェクトとプロファイル

- [テストプロジェクトの作成](reference/project/creating_project_ja.md)
- [プロファイル(アプリ / 実行)](reference/project/profiles_ja.md)
- [実行プロファイルの設定項目](reference/project/run_profile_ja.md)

### テストクラスの作成

- [テストクラスの作成](reference/testclass/creating_testclass_ja.md)
- [要素の選択と検証](reference/testclass/select_and_assert_ja.md)
- [テキストの視覚検証の判定](reference/testclass/text_visual_check_ja.md)
- [テストコードの構造](reference/testclass/testcode_structure_ja.md)
- [独自コマンド](reference/testclass/custom_commands_ja.md)
- [テスト結果ファイル](reference/testclass/test_result_files_ja.md)

### セレクタ

- [セレクタ式](reference/selector/selector_expression_ja.md)
- [相対セレクタとスコープ](reference/selector/relative_selector_ja.md)
- [型付きセレクタ(Sel)](reference/selector/typed_selector_ja.md)
- [WebView 内の要素](reference/selector/webview_ja.md)

### 関数/プロパティ

- 要素のタップ
    - [tap, tapAppIcon](reference/commands/tap_ja.md)
- 要素の選択
    - [select, lastElement](reference/commands/select_ja.md)
    - [画像で探す(findImage, findImages, existImage)](reference/commands/find_image_ja.md)
- アプリのインストールと起動
    - [installApp, removeApp, clearAppData](reference/commands/install_app_ja.md)
    - [launchApp, restartApp, terminateApp, openURL](reference/commands/launch_app_ja.md)
- ナビゲーション
    - [home, back, appSwitcher, rotateTo](reference/commands/navigation_ja.md)
- 画面のスワイプ/スクロール
    - [swipe, swipePointToPoint, swipeElementToElement, swipeBy](reference/commands/swipe_ja.md)
    - [スクロール(scrollTo, scrollDown, withScrollDown, scrollFrame, …)](reference/commands/scroll_ja.md)
    - [flick](reference/commands/flick_ja.md)
    - [マップ・キャンバス系のジェスチャ(doubleTap, pinchIn, pinchOut, gesture, hold)](reference/commands/gestures_ja.md)
- 編集とキーボード操作
    - [type](reference/commands/type_ja.md)
    - [clearInput](reference/commands/clear_input_ja.md)
    - [pressEnter, hideKeyboard](reference/commands/press_enter_hide_keyboard_ja.md)
- 存在の検証
    - [exist, notExist, countIs](reference/commands/existence_assertion_ja.md)
- 属性の検証
    - [テキストの検証(textIs, textContains, …)](reference/commands/text_assertion_ja.md)
    - [値の検証(valueIs, valueContains, …)](reference/commands/value_assertion_ja.md)
    - [id の検証(idIs)](reference/commands/id_assertion_ja.md)
    - [状態の検証(enabledIsTrue, enabledIsFalse, checkIsON, checkIsOFF)](reference/commands/state_assertion_ja.md)
    - [画像の検証(imageIs)](reference/commands/image_assertion_ja.md)
- その他の検証
    - [キーボードの検証(keyboardIsShown, keyboardIsNotShown)](reference/commands/keyboard_assertion_ja.md)
    - [画面の検証(screenLooksLike)](reference/commands/screen_assertion_ja.md)
    - [アプリの検証(appIs)](reference/commands/app_assertion_ja.md)
- 任意の値の検証
    - [任意の値の検証(thisIs, thisContains, …)](reference/commands/any_value_assertion_ja.md)
- まとめて検証
    - [まとめて検証(verify)](reference/commands/verify_ja.md)
- 値の読み出し
    - [掴んだ要素の値を読む(.text, .value, .id, lastElement)](reference/commands/reading_values_ja.md)
- シナリオ間で値を共有
    - [メモ(writeMemo, readMemo, clearMemo, memoTextAs)](reference/commands/memo_ja.md)
    - [出力フォルダと一時フォルダ(TestLog)](reference/commands/test_log_ja.md)
- 分岐
    - [ifCanSelect, ios, android](reference/commands/branch_ja.md)
- 反復
    - [repeatWhileCanSelect, doUntilTrue](reference/commands/repeat_ja.md)
- 同期
    - [wait, waitForDisplay, waitForClose](reference/commands/wait_ja.md)
- 記述子
    - [group, procedure, beforeEach, afterEach](reference/commands/descriptors_ja.md)
- スクリーンショット
    - [screenshot](reference/commands/screenshot_ja.md)
- イレギュラーの処理
    - [irregularHandler](reference/commands/irregular_handler_ja.md)
    - [suppressHandler, useHandler, disableHandler, enableHandler](reference/commands/suppress_handler_ja.md)
    - [iOS のシステムアラート(iosAlertHandler)](reference/commands/ios_alert_handler_ja.md)

### 実行

- [シナリオの実行(fleetest run)](reference/running/running_scenarios_ja.md)
- [dry-run(No-Load-Run)](reference/running/dry_run_ja.md)
- [自己修復](reference/running/self_healing_ja.md)
- [並列実行](reference/running/parallel_execution_ja.md)
- [結果の分析(fleetest results・ダッシュボード)](reference/running/results_analysis_ja.md)

### ツール

- [VSCode 拡張](reference/tools/vscode_extension_ja.md)
- [MCP サーバ](reference/tools/mcp_server_ja.md)
- [Claude Code のスキル](reference/tools/claude_code_skills_ja.md)
- [Claude Code 以外の AIアシスタント](reference/tools/other_agents_ja.md)
- [エージェント向けの手引き](reference/tools/agent_guide_ja.md)

### シナリオの書き方

- [壊れにくいシナリオの書き方](reference/writing/writing_robust_scenarios_ja.md)
- [UI 部品ごとの書き方と癖](reference/writing/ui_component_patterns_ja.md)

### 仕様

- [DSL コマンドリファレンス](../commands.md)
- [結果 JSON のスキーマ](../results-json.md)
- [Shirates 利用者向けの対応表](overview/for_shirates_users_ja.md)
