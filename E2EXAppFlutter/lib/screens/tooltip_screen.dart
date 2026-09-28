import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class TooltipScreen extends StatefulWidget {
  const TooltipScreen({super.key});

  @override
  State<TooltipScreen> createState() => _TooltipScreenState();
}

// Flutter の Tooltip は表示継続時間を明示できる(showDuration)が、非表示になった瞬間を
// 通知する public API が無い(Compose の tooltipState.isVisible に相当するものが無い)。
// onTriggered で「表示された」ことは分かるので、そこから showDuration と同じ長さだけ
// 待ってから hidden に倒す近似値で txt_tooltip_state を出す(実際の非表示タイミングの
// 直接観測ではない。docs/ui-contract.md に明記)。
const _showDuration = Duration(seconds: 2);

class _TooltipScreenState extends State<TooltipScreen> {
  String _state = 'hidden';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ツールチップ',
        body: ScreenColumn(children: [
          TaggedText(Tags.tooltipState, 'tooltip=$_state'),
          // Tooltip の吹き出し本文(#txt_tooltip 相当)には id を付けられない
          // (message/richMessage はカスタム Widget を差し込めない Flutter の制約)。
          // ラベルで指す前提(docs/ui-contract.md)。
          Tooltip(
            message: 'これはツールチップです',
            triggerMode: TooltipTriggerMode.longPress,
            showDuration: _showDuration,
            // アンカーの意味付けは #btn_tooltip_anchor 側の label('情報')に一本化する
            // (Tooltip 自身の message を semantics へ二重に出さない)。
            excludeFromSemantics: true,
            onTriggered: () {
              setState(() => _state = 'shown');
              Future.delayed(_showDuration, () {
                if (mounted) setState(() => _state = 'hidden');
              });
            },
            child: tagged(
              Tags.btnTooltipAnchor,
              IconButton(icon: const Icon(Icons.info_outline), onPressed: () {}),
              button: true,
              label: '情報',
            ),
          ),
        ]),
      );
}
