import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class ReorderScreen extends StatefulWidget {
  const ReorderScreen({super.key});

  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  final _order = List.generate(Tags.reorderRowCount, (i) => i + 1);

  // removeAt+insert は1回で離した位置へ直接移す(隣との1回の入れ替えではない。何個下で
  // 離しても newIndex がその最終位置を指す)。onReorderItem は除去後の newIndex を渡すため
  // oldIndex>newIndex の補正も不要(onReorder は補正が要り、v3.41 で非推奨)。
  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _order.removeAt(oldIndex);
      _order.insert(newIndex, item);
    });
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '並べ替え',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.reorderResult, 'order=${_order.join(',')}'),
            ),
            Expanded(
              // ReorderableListView は既定でハンドル(掴んで動かす形)を各行に付ける。
              // 長押しで直接ドラッグする形も端末のドラッグ操作として並行に効く。
              child: ReorderableListView(
                onReorderItem: _onReorder,
                children: [
                  for (final n in _order)
                    ListTile(
                      key: ValueKey(n),
                      title: tagged(Tags.reorderRow(n), Text(Tags.reorderRowLabel(n))),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}
