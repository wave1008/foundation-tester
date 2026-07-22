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
        // **高コントラスト固定**(Material 3 の淡い着色を使わない)。M3 既定の薄紫背景 +
        // 薄紫文字だと、ftester の occlusion-guard(exist の requireVisible)が低インクと判定して
        // FM 視覚照合を呼び、FM が「覆われている」と誤判定して exist が落ちる
        // (実測: 実際には完全に見えている。2026-07-23)。
        // この SUT の目的は DSL の検証であって FM の視覚精度の検証ではないため、
        // 他の SUT(白背景・黒文字)と同じ見た目に揃えて FM を呼ばせない。
        theme: ThemeData(
          useMaterial3: false,
          scaffoldBackgroundColor: Colors.white,
          canvasColor: Colors.white,
        ),
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
