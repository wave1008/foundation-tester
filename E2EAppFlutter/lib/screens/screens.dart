import 'package:flutter/material.dart';

import '../main.dart';
import '../tags.dart';
import '../widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.onNavigate, super.key});

  final void Function(Screen) onNavigate;

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        const TaggedText(Tags.homeMarker, 'E2E ホーム'),
        TaggedButton(Tags.navSelector, 'セレクタ',
            fillWidth: true, onTap: () => onNavigate(Screen.selector)),
        TaggedButton(Tags.navInput, 'テキスト入力',
            fillWidth: true, onTap: () => onNavigate(Screen.input)),
        TaggedButton(Tags.navGesture, 'ジェスチャ',
            fillWidth: true, onTap: () => onNavigate(Screen.gesture)),
        TaggedButton(Tags.navScroll, 'スクロール',
            fillWidth: true, onTap: () => onNavigate(Screen.scroll)),
        TaggedButton(Tags.navAsync, '非同期表示',
            fillWidth: true, onTap: () => onNavigate(Screen.async)),
        TaggedButton(Tags.navDialog, 'ダイアログ',
            fillWidth: true, onTap: () => onNavigate(Screen.dialog)),
        TaggedButton(Tags.navLifecycle, 'ライフサイクル',
            fillWidth: true, onTap: () => onNavigate(Screen.lifecycle)),
        TaggedButton(Tags.navHeal, '自己修復',
            fillWidth: true, onTap: () => onNavigate(Screen.heal)),
        TaggedButton(Tags.navDiagnostics, '診断',
            fillWidth: true, onTap: () => onNavigate(Screen.diagnostics)),
      ]);
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => const ScreenColumn(children: [
        TaggedText(Tags.txtAboutMarker, 'E2E について'),
        TaggedText(Tags.txtAboutApp, 'app=${AppInfo.appId}'),
        TaggedText(Tags.txtAboutVersion, 'version=${AppInfo.version}'),
      ]);
}

class SelectorScreen extends StatefulWidget {
  const SelectorScreen({super.key});

  @override
  State<SelectorScreen> createState() => _SelectorScreenState();
}

class _SelectorScreenState extends State<SelectorScreen> {
  String _result = '-';

  void _set(String v) => setState(() => _result = v);

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        TaggedText(Tags.selectorResult, 'result=$_result'),
        // 「許可」⊂「通知を許可」の部分一致衝突は契約で意図的に作られた検証材料。
        TaggedButton(Tags.btnAllow, '許可', onTap: () => _set('allow')),
        TaggedButton(Tags.btnAllowNotification, '通知を許可',
            onTap: () => _set('allow_notification')),
        // 同一ラベル「項目」の3連。ラベル指定では曖昧・#id か .Type[n] でのみ引ける。
        TaggedButton(Tags.btnItem1, '項目', onTap: () => _set('item1')),
        TaggedButton(Tags.btnItem2, '項目', onTap: () => _set('item2')),
        TaggedButton(Tags.btnItem3, '項目', onTap: () => _set('item3')),
        const TaggedText(Tags.txtSharedLabel, '共通ラベル'),
        TaggedButton(Tags.btnSharedLabel, '共通ラベル', onTap: () => _set('shared')),
        TaggedButton(Tags.btnAliasNew, '別名ボタン', onTap: () => _set('alias')),
        TaggedButton(Tags.btnSelectorReset, '結果クリア', onTap: () => _set('-')),
        // 700dp: 初期表示では絶対に画面内に入らない高さ(scrollTo / requireVisible の検証材料)。
        const SizedBox(height: 700),
        const TaggedText(Tags.txtOffscreen, '画面外テキスト'),
      ]);
}

// レイアウトはソフトキーボードに支配される(Compose 版と同じ制約)。スクロールさせず、
// シナリオが触る要素(echo 4本 + 単一行/パスワード欄 + 送信/クリア)を画面上部に固める。
class InputScreen extends StatefulWidget {
  const InputScreen({super.key});

  @override
  State<InputScreen> createState() => _InputScreenState();
}

class _InputScreenState extends State<InputScreen> {
  final _single = TextEditingController();
  final _password = TextEditingController();
  final _multiline = TextEditingController();
  String _submitted = '-';

  @override
  void dispose() {
    _single.dispose();
    _password.dispose();
    _multiline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScreenColumn(scrollable: false, children: [
        TaggedText(Tags.echoSingle, 'single=${_single.text}'),
        TaggedText(Tags.echoPassword, 'password=${_password.text}'),
        TaggedText(Tags.echoLength, 'len=${_single.text.length}'),
        TaggedText(Tags.txtInputSubmitted, 'submitted=$_submitted'),
        tagged(
          Tags.fieldSingle,
          TextField(
            controller: _single,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: '単一行'),
          ),
        ),
        tagged(
          Tags.fieldPassword,
          TextField(
            controller: _password,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'パスワード'),
          ),
        ),
        Row(children: [
          Expanded(
            child: TaggedButton(Tags.btnInputSubmit, '送信',
                fillWidth: true, onTap: () => setState(() => _submitted = _single.text)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TaggedButton(Tags.btnInputClear, '入力クリア', fillWidth: true, onTap: () {
              _single.clear();
              _password.clear();
              _multiline.clear();
              setState(() => _submitted = '-');
            }),
          ),
        ]),
        TaggedText(Tags.echoMultiline, 'multiline=${_multiline.text.replaceAll('\n', ' ')}'),
        tagged(
          Tags.fieldMultiline,
          TextField(
            controller: _multiline,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: '複数行'),
          ),
        ),
      ]);
}

class LifecycleScreen extends StatefulWidget {
  const LifecycleScreen({super.key});

  @override
  State<LifecycleScreen> createState() => _LifecycleScreenState();
}

class _LifecycleScreenState extends State<LifecycleScreen> {
  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        TaggedText(Tags.txtLaunchCount, 'launch=${LaunchCounter.value}'),
        TaggedText(Tags.txtSessionCount, 'session=${SessionCounter.value}'),
        TaggedButton(Tags.btnSessionInc, 'セッション+1',
            onTap: () => setState(() => SessionCounter.value += 1)),
        TaggedButton(Tags.btnResetPersisted, '永続カウンタをリセット', onTap: () async {
          await LaunchCounter.reset();
          if (mounted) setState(() {});
        }),
        TaggedText(Tags.txtPlatform,
            'platform=${Theme.of(context).platform == TargetPlatform.iOS ? 'iOS' : 'Android'}'),
      ]);
}

class HealScreen extends StatefulWidget {
  const HealScreen({super.key});

  @override
  State<HealScreen> createState() => _HealScreenState();
}

class _HealScreenState extends State<HealScreen> {
  late bool _schemaV1 = prefs.getBool('heal_schema_v1') ?? true;
  String _tapped = '-';

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('旧ID(v1)を使う'),
          tagged(
            Tags.swHealSchema,
            Switch(
              value: _schemaV1,
              onChanged: (v) async {
                await prefs.setBool('heal_schema_v1', v);
                setState(() => _schemaV1 = v);
              },
            ),
          ),
        ]),
        TaggedText(Tags.txtHealSchema, 'schema=${_schemaV1 ? 'v1' : 'v2'}'),
        // ラベル固定・id のみ切替がヒール検証の核。
        TaggedButton(_schemaV1 ? Tags.btnHealV1 : Tags.btnHealV2, '修復対象',
            onTap: () => setState(() => _tapped = _schemaV1 ? 'v1' : 'v2')),
        TaggedText(Tags.txtHealResult, 'tapped=$_tapped'),
        TaggedButton(Tags.btnHealReset, '修復結果クリア',
            onTap: () => setState(() => _tapped = '-')),
      ]);
}
