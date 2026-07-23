import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/screens.dart';
import 'screens/screens2.dart';
import 'tags.dart';
import 'widgets.dart';

// 永続化キーは "launch_count" / "auto_dialog" / "heal_schema_v1" の3つのみ
// (E2EApp/docs/ui-contract.md §永続化する値)。
late SharedPreferences prefs;

/// プロセス起動ごとに +1。main() から1回だけ呼ぶ。
class LaunchCounter {
  static int value = 0;

  static Future<void> count() async {
    value = (prefs.getInt('launch_count') ?? 0) + 1;
    await prefs.setInt('launch_count', value);
  }

  static Future<void> reset() async {
    value = 1;
    await prefs.setInt('launch_count', 1);
  }
}

/// プロセス内メモリのみ。relaunch でのみ 0 に戻ることが検証要件。
class SessionCounter {
  static int value = 0;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // **必須**: Flutter の semantics ツリーは支援技術が要求したときだけ構築される。
  // ensureSemantics() で常時 ON にしないと、ブリッジによっては要素が1つも見えない
  // (= どのセレクタも解決できない)。E2E 用アプリなので恒久的に有効化する。
  SemanticsBinding.instance.ensureSemantics();
  prefs = await SharedPreferences.getInstance();
  await LaunchCounter.count();
  runApp(const E2EApp());
}

enum Screen { selector, input, gesture, scroll, async, dialog, lifecycle, heal, diagnostics }

enum AppTab { home, controls, about }

class E2EApp extends StatelessWidget {
  const E2EApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'FT E2E Flutter',
        debugShowCheckedModeBanner: false,
        // **Material 3 の既定配色(淡い着色)をそのまま使う**。ここを白背景・黒文字の
        // 高コントラストに変えると、ftester の occlusion-guard(FM 視覚照合)が
        // 低コントラスト画面で誤判定する欠陥を SUT が踏まなくなり、**検出器を潰す**ことになる。
        // M3 既定はごく普通の実アプリの見た目であり、そこで落ちるなら SUT ではなく
        // ftester 側の問題(docs/design.md §5・Projects/E2E-Flutter/README.md の既知欠陥)。
        home: const AppShell(),
      );
}

// プロセス起動ごとに State が初期値へ戻る = 「起動時は必ずホームタブのルート」契約が成立する。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppTab _tab = AppTab.home;
  Screen? _homeChild;

  String get _title {
    switch (_tab) {
      case AppTab.controls:
        return 'コントロール';
      case AppTab.about:
        return '情報';
      case AppTab.home:
        switch (_homeChild) {
          case null:
            return 'ホーム';
          case Screen.selector:
            return 'セレクタ';
          case Screen.input:
            return 'テキスト入力';
          case Screen.gesture:
            return 'ジェスチャ';
          case Screen.scroll:
            return 'スクロール';
          case Screen.async:
            return '非同期表示';
          case Screen.dialog:
            return 'ダイアログ';
          case Screen.lifecycle:
            return 'ライフサイクル';
          case Screen.heal:
            return '自己修復';
          case Screen.diagnostics:
            return '診断';
        }
    }
  }

  /// タブ切替は下位画面スタックを捨てて各タブのルートへ着地する(契約 §シェル)。
  void _switchTab(AppTab next) => setState(() {
        _tab = next;
        _homeChild = null;
      });

  Widget get _content {
    switch (_tab) {
      case AppTab.controls:
        return const ControlsScreen();
      case AppTab.about:
        return const AboutScreen();
      case AppTab.home:
        switch (_homeChild) {
          case null:
            return HomeScreen(onNavigate: (s) => setState(() => _homeChild = s));
          case Screen.selector:
            return const SelectorScreen();
          case Screen.input:
            return const InputScreen();
          case Screen.gesture:
            return const GestureScreen();
          case Screen.scroll:
            return const ScrollScreen();
          case Screen.async:
            return const AsyncScreen();
          case Screen.dialog:
            return const DialogScreen();
          case Screen.lifecycle:
            return const LifecycleScreen();
          case Screen.heal:
            return const HealScreen();
          case Screen.diagnostics:
            return const DiagnosticsScreen();
        }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        // resizeToAvoidBottomInset=false: キーボードで列が動くと入力欄がキーボード下へ
        // 回り込んでロケータが解決できなくなる(Compose 版で実測した罠と同じ)。
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (_homeChild != null)
                      TaggedButton(Tags.back, '戻る',
                          onTap: () => setState(() => _homeChild = null)),
                    const SizedBox(width: 8),
                    TaggedText(Tags.screenTitle, _title),
                  ],
                ),
              ),
              Expanded(child: _content),
              Row(
                children: [
                  Expanded(
                      child: TaggedButton(Tags.tabHome, 'ホーム',
                          fillWidth: true, onTap: () => _switchTab(AppTab.home))),
                  Expanded(
                      child: TaggedButton(Tags.tabControls, 'コントロール',
                          fillWidth: true, onTap: () => _switchTab(AppTab.controls))),
                  Expanded(
                      child: TaggedButton(Tags.tabAbout, '情報',
                          fillWidth: true, onTap: () => _switchTab(AppTab.about))),
                ],
              ),
            ],
          ),
        ),
      );
}
