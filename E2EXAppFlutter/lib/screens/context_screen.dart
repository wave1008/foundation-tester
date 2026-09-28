import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class ContextScreen extends StatefulWidget {
  const ContextScreen({super.key});

  @override
  State<ContextScreen> createState() => _ContextScreenState();
}

class _ContextScreenState extends State<ContextScreen> {
  String _result = 'none';

  // メニュー項目のラベル→echo に使う action key(例: 複製→copy)。
  static const _actions = [('編集', 'edit'), ('複製', 'copy'), ('削除', 'delete')];

  Future<void> _openMenu(BuildContext context, Offset position, int row) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final (label, key) in _actions) PopupMenuItem(value: key, child: Text(label)),
      ],
    );
    if (selected != null) {
      setState(() => _result = 'row$row:$selected');
    }
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '長押しメニュー',
        body: ScreenColumn(children: [
          TaggedText(Tags.contextResult, 'context=$_result'),
          for (var n = 1; n <= Tags.ctxRowCount; n++)
            tagged(
              Tags.ctxRow(n),
              GestureDetector(
                onLongPressStart: (details) => _openMenu(context, details.globalPosition, n),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  alignment: Alignment.centerLeft,
                  color: Colors.black.withValues(alpha: 0.03),
                  child: Text(Tags.ctxRowLabel(n)),
                ),
              ),
              button: true,
            ),
        ]),
      );
}
