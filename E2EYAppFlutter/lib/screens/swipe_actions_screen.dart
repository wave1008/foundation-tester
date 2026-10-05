import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../tags.dart';
import '../widgets.dart';

class SwipeActionsScreen extends StatefulWidget {
  const SwipeActionsScreen({super.key});

  @override
  State<SwipeActionsScreen> createState() => _SwipeActionsScreenState();
}

class _SwipeActionsScreenState extends State<SwipeActionsScreen> {
  final List<int> _rows = List.generate(Tags.swipeRowCount, (i) => i + 1);
  String _action = 'none';
  String _reply = 'none';

  void _setAction(String v) => setState(() => _action = v);

  Widget _button(
    String tag,
    String label,
    Color color,
    VoidCallback onPressed,
  ) => CustomSlidableAction(
    onPressed: (_) => onPressed(),
    backgroundColor: color,
    foregroundColor: Colors.white,
    padding: EdgeInsets.zero,
    child: tagged(
      tag,
      Center(
        child: Text(label, style: const TextStyle(color: Colors.white)),
      ),
      button: true,
    ),
  );

  Widget _row(int n) => Slidable(
    key: ValueKey(n),
    startActionPane: ActionPane(
      motion: const BehindMotion(),
      extentRatio: 0.3,
      children: [
        _button(
          Tags.swPin(n),
          'ピン留め',
          Colors.orange,
          () => _setAction('row$n:pin'),
        ),
      ],
    ),
    endActionPane: ActionPane(
      motion: const BehindMotion(),
      extentRatio: 0.6,
      // 行幅の大半(既定 0.75)を越えて払うとボタンを押さずに削除まで走る
      dismissible: DismissiblePane(
        motion: const BehindMotion(),
        onDismissed: () => setState(() {
          _rows.remove(n);
          _action = 'row$n:delete';
        }),
      ),
      children: [
        _button(
          Tags.swArchive(n),
          'アーカイブ',
          Colors.blueGrey,
          () => _setAction('row$n:archive'),
        ),
        _button(Tags.swDelete(n), '削除', Colors.red, () {
          setState(() {
            _rows.remove(n);
            _action = 'row$n:delete';
          });
        }),
      ],
    ),
    child: Builder(
      builder: (ctx) => tagged(
        Tags.swRow(n),
        ListTile(
          title: Text(Tags.swRowLabel(n)),
          onTap: () {
            final c = Slidable.of(ctx);
            if (c != null && c.ratio != 0) {
              c.close();
            } else {
              _setAction('row$n:open');
            }
          },
        ),
        button: true,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: 'スワイプの操作',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TaggedText(Tags.swipeActionsResult, 'action=$_action'),
                TaggedText(Tags.swipeActionsCount, 'rows=${_rows.length}'),
                TaggedText(Tags.replyTarget, 'reply=$_reply'),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final n in _rows) _row(n),
              const Divider(),
              for (var n = 1; n <= Tags.replyRowCount; n++)
                _ReplyRow(
                  n: n,
                  onReply: () => setState(() => _reply = Tags.replyRow(n)),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 左から右へ行幅の 25% を越えて離すと返信(行は元の位置へ戻る)。自前のドラッグ検出
class _ReplyRow extends StatefulWidget {
  const _ReplyRow({required this.n, required this.onReply});

  final int n;
  final VoidCallback onReply;

  @override
  State<_ReplyRow> createState() => _ReplyRowState();
}

class _ReplyRowState extends State<_ReplyRow> {
  static const _threshold = 0.25;
  double _dx = 0;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => setState(() => _dragging = true),
      onHorizontalDragUpdate: (d) => setState(
        () => _dx = (_dx + d.delta.dx).clamp(0.0, box.maxWidth * 0.5),
      ),
      onHorizontalDragEnd: (_) {
        if (_dx >= box.maxWidth * _threshold) widget.onReply();
        setState(() {
          _dx = 0;
          _dragging = false;
        });
      },
      onHorizontalDragCancel: () => setState(() {
        _dx = 0;
        _dragging = false;
      }),
      child: AnimatedContainer(
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 150),
        transform: Matrix4.translationValues(_dx, 0, 0),
        child: tagged(
          Tags.replyRow(widget.n),
          ListTile(title: Text(Tags.replyRowLabel(widget.n))),
          button: true,
        ),
      ),
    ),
  );
}
