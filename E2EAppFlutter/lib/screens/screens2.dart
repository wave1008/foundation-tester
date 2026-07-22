import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../tags.dart';
import '../widgets.dart';

// ブリッジの swipe は要素を狙わず画面を払う
// (iOS は XCUITest の XCUIApplication.swipeUp() 等でアプリ frame 全体を払う。
//  Android は BridgeRouter.handleSwipe が縦 0.3h↔0.7h / 横 0.2w↔0.8w の固定座標)。
// よって #pad_swipe はコンテンツ領域いっぱいに敷き、操作要素はその上に重ねる。
// ボタン類は始点を塞がないよう幅 45% 以内(中央列を空ける)かつ上下の端に置く。
class GestureScreen extends StatefulWidget {
  const GestureScreen({super.key});

  @override
  State<GestureScreen> createState() => _GestureScreenState();
}

class _GestureScreenState extends State<GestureScreen> {
  int _tap = 0;
  int _press = 0;
  String _swipe = '-';
  String _last = '-';

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => Stack(children: [
          Positioned.fill(
            child: tagged(
              Tags.padSwipe,
              GestureDetector(
                onPanEnd: (details) {
                  // 判定は指の移動方向(上へ払う = up)。ブリッジの direction 定義と一致させる契約。
                  final v = details.velocity.pixelsPerSecond;
                  setState(() {
                    _swipe = v.dx.abs() > v.dy.abs()
                        ? (v.dx < 0 ? 'left' : 'right')
                        : (v.dy < 0 ? 'up' : 'down');
                    _last = 'swipe';
                  });
                },
                child: Container(
                  color: const Color(0xFFEEEEEE),
                  alignment: Alignment.center,
                  child: const Text('スワイプ領域'),
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            width: constraints.maxWidth * 0.45,
            child: Column(children: [
              TaggedButton(Tags.btnTapCounter, 'タップ',
                  fillWidth: true,
                  onTap: () => setState(() {
                        _tap += 1;
                        _last = 'tap';
                      })),
              const SizedBox(height: 8),
              // 通常タップでは増えず長押しでのみ増える要素。
              // label は子の Text から MergeSemantics 経由で拾う。ここで label: を書くと
              // 「長押し\n長押し」と二重になる(実測)。
              tagged(
                Tags.btnLongPress,
                button: true,
                Semantics(
                  child: GestureDetector(
                    onLongPress: () => setState(() {
                      _press += 1;
                      _last = 'longpress';
                    }),
                    child: Container(
                      height: 56,
                      alignment: Alignment.center,
                      color: Colors.blue,
                      child: const Text('長押し', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              TaggedText(Tags.txtTapCount, 'tap=$_tap'),
              TaggedText(Tags.txtPressCount, 'press=$_press'),
              TaggedText(Tags.txtSwipeDir, 'swipe=$_swipe'),
              TaggedText(Tags.txtLastGesture, 'last=$_last'),
            ]),
          ),
          Positioned(
            bottom: 12,
            left: 12,
            width: constraints.maxWidth * 0.45,
            child: TaggedButton(Tags.btnGestureReset, 'ジェスチャクリア',
                fillWidth: true,
                onTap: () => setState(() {
                      _tap = 0;
                      _press = 0;
                      _swipe = '-';
                      _last = '-';
                    })),
          ),
        ]),
      );
}

class ScrollScreen extends StatefulWidget {
  const ScrollScreen({super.key});

  @override
  State<ScrollScreen> createState() => _ScrollScreenState();
}

class _ScrollScreenState extends State<ScrollScreen> {
  final _controller = ScrollController();
  String _selected = '-';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TaggedText(Tags.txtRowSelected, 'selected=$_selected'),
          TaggedButton(Tags.btnScrollTop, '先頭へ',
              onTap: () => _controller.jumpTo(0)),
          Expanded(
            child: ListView.builder(
              controller: _controller,
              // 下端の余白: これが無いと最終行がビューポート下端に貼り付いたまま止まり、
              // iOS では frame がクランプされて座標タップが外れる(design.md §4.6)。
              padding: const EdgeInsets.only(bottom: 80),
              // **cacheExtent: 0 は必須**。既定(250px)だと画面外の先読み行まで semantics に
              // 出るうえ、iOS ではその frame がビューポート内にクランプされて報告される。
              // すると scrollTo が「まだ画面外の #row_40 を見つけた」と判断して停止し、
              // 続くタップがクランプ座標(実際には何も無い場所)を叩いて空振りする(実測)。
              cacheExtent: 0,
              itemCount: Tags.rowCount,
              itemBuilder: (context, index) {
                final n = index + 1;
                // 56dp 以上: これ未満だと高密度スクロールで frame がクランプされ tap が外れる。
                // button: true を付けないと行が StaticText になり型セレクタで区別できない。
                return tagged(
                  Tags.row(n),
                  button: true,
                  InkWell(
                    onTap: () => setState(() => _selected = Tags.row(n)),
                    child: SizedBox(
                      height: 56,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(Tags.rowLabel(n)),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ]),
      );
}

class AsyncScreen extends StatefulWidget {
  const AsyncScreen({super.key});

  @override
  State<AsyncScreen> createState() => _AsyncScreenState();
}

class _AsyncScreenState extends State<AsyncScreen> {
  String _state = 'idle';
  bool _showDelayed = false;
  int? _countdown;
  final List<Timer> _timers = [];

  void _cancelTimers() {
    // 前回タイマを消さないと、古い遅延が後から done を書き込んで検証を壊す。
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  void _startDelay(int seconds, {required bool withCountdown}) {
    _cancelTimers();
    setState(() {
      _state = 'waiting';
      _showDelayed = false;
      _countdown = null;
    });
    if (withCountdown) {
      for (var n = seconds; n >= 0; n--) {
        _timers.add(Timer(Duration(seconds: seconds - n), () {
          if (mounted) setState(() => _countdown = n);
        }));
      }
    }
    _timers.add(Timer(Duration(seconds: seconds), () {
      if (mounted) {
        setState(() {
          _state = 'done';
          _showDelayed = true;
        });
      }
    }));
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        TaggedText(Tags.txtDelayState, 'state=$_state'),
        TaggedButton(Tags.btnDelay1, '1秒後に表示',
            onTap: () => _startDelay(1, withCountdown: false)),
        TaggedButton(Tags.btnDelay3, '3秒後に表示',
            onTap: () => _startDelay(3, withCountdown: true)),
        TaggedButton(Tags.btnDelay8, '8秒後に表示',
            onTap: () => _startDelay(8, withCountdown: false)),
        // 待機中はツリーに置かない(非表示ではなく未配置であることが検証点)。
        if (_showDelayed) const TaggedText(Tags.txtDelayed, '遅延表示 完了'),
        if (_countdown != null) TaggedText(Tags.txtCountdown, 'count=$_countdown'),
        TaggedButton(Tags.btnAsyncReset, '非同期リセット', onTap: () {
          _cancelTimers();
          setState(() {
            _state = 'idle';
            _showDelayed = false;
            _countdown = null;
          });
        }),
      ]);
}

class DialogScreen extends StatefulWidget {
  const DialogScreen({super.key});

  @override
  State<DialogScreen> createState() => _DialogScreenState();
}

class _DialogScreenState extends State<DialogScreen> {
  String _result = 'none';
  int _maybeCount = 0;
  late bool _auto = prefs.getBool('auto_dialog') ?? false;

  @override
  void initState() {
    super.initState();
    // auto=on のとき、この画面に入るたびダイアログを自動で開く。
    if (_auto) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showDialog());
    }
  }

  void _showDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const TaggedText(Tags.txtDialogTitle, '確認'),
        actions: [
          TaggedButton(Tags.btnDialogCancel, 'キャンセル', onTap: () {
            setState(() => _result = 'cancel');
            Navigator.of(context).pop();
          }),
          TaggedButton(Tags.btnDialogOk, 'OK', onTap: () {
            setState(() => _result = 'ok');
            Navigator.of(context).pop();
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        TaggedText(Tags.txtDialogResult, 'dialog=$_result'),
        TaggedButton(Tags.btnShowDialog, 'ダイアログを開く', onTap: _showDialog),
        TaggedButton(Tags.btnMaybeDialog, '交互にダイアログ', onTap: () {
          _maybeCount += 1;
          // 乱数不使用: 奇数回目だけ開く決定的な交互動作が検証要件。
          if (_maybeCount % 2 == 1) _showDialog();
        }),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('起動時ダイアログ'),
          tagged(
            Tags.swAutoDialog,
            Switch(
              value: _auto,
              onChanged: (v) async {
                await prefs.setBool('auto_dialog', v);
                setState(() => _auto = v);
              },
            ),
          ),
        ]),
        TaggedText(Tags.txtAutoDialog, 'auto=${_auto ? 'on' : 'off'}'),
      ]);
}

class ControlsScreen extends StatefulWidget {
  const ControlsScreen({super.key});

  @override
  State<ControlsScreen> createState() => _ControlsScreenState();
}

class _ControlsScreenState extends State<ControlsScreen> {
  bool _notify = false;
  bool _agree = false;
  String _plan = 'A';
  double _volume = 50;

  Widget _planRow(String value, String tag, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          tagged(
            tag,
            Radio<String>(
              value: value,
              groupValue: _plan,
              onChanged: (v) => setState(() => _plan = v!),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        // ラベル Text とコントロール本体を別要素にする(タップ対象は本体のみ)。
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('通知'),
          tagged(
            Tags.swNotify,
            Switch(value: _notify, onChanged: (v) => setState(() => _notify = v)),
          ),
        ]),
        TaggedText(Tags.txtSwNotify, 'notify=${_notify ? 'on' : 'off'}'),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('同意する'),
          tagged(
            Tags.cbAgree,
            Checkbox(value: _agree, onChanged: (v) => setState(() => _agree = v!)),
          ),
        ]),
        TaggedText(Tags.txtCbAgree, 'agree=$_agree'),
        _planRow('A', Tags.radioA, 'プランA'),
        _planRow('B', Tags.radioB, 'プランB'),
        _planRow('C', Tags.radioC, 'プランC'),
        TaggedText(Tags.txtRadio, 'plan=$_plan'),
        // divisions=4: 0..100 を 25 刻みの 5 段(0/25/50/75/100)にする契約値。
        Semantics(
          identifier: Tags.sliderVolume,
          child: Slider(
            value: _volume,
            min: 0,
            max: 100,
            divisions: 4,
            onChanged: (v) => setState(() => _volume = v),
          ),
        ),
        TaggedText(Tags.txtSlider, 'volume=${_volume.round()}'),
        TaggedButton(Tags.btnControlsReset, 'コントロールリセット',
            onTap: () => setState(() {
                  _notify = false;
                  _agree = false;
                  _plan = 'A';
                  _volume = 50;
                })),
      ]);
}

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) => ScreenColumn(children: [
        const TaggedText(Tags.txtBuildInfo, 'build=${AppInfo.version}'),
        const TaggedText(Tags.txtDiagNote, '診断メニュー'),
        TaggedButton(Tags.btnFreeze3s, '3秒フリーズ', onTap: () {
          // ブリッジのタイムアウト挙動検証用に UI スレッドを 3 秒ブロックする。
          final end = DateTime.now().add(const Duration(seconds: 3));
          while (DateTime.now().isBefore(end)) {}
        }),
        TaggedButton(Tags.btnCrash, 'クラッシュさせる', onTap: () {
          showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('クラッシュ確認'),
              actions: [
                TaggedButton(Tags.btnCrashCancel, 'やめる',
                    onTap: () => Navigator.of(context).pop()),
                // 押すと即プロセス異常終了する。クラッシュレポート添付の検証専用。
                TaggedButton(Tags.btnCrashConfirm, '本当にクラッシュ', onTap: () {
                  Navigator.of(context).pop();
                  throw StateError('FT_E2E intentional crash');
                }),
              ],
            ),
          );
        }),
      ]);
}
