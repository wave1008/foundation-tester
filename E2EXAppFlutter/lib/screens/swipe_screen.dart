import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class SwipeScreen extends StatefulWidget {
  const SwipeScreen({super.key});

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen> {
  final List<int> _rows = List.generate(Tags.swipeRowCount, (i) => i + 1);
  String _removed = 'none';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'スワイプで削除',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaggedText(Tags.swipeResult, 'removed=$_removed'),
                  TaggedText(Tags.swipeCount, 'rows=${_rows.length}'),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final n in _rows)
                    Dismissible(
                      key: ValueKey(n),
                      // 右→左だけ有効(左→右は無効。契約 §スワイプで削除)。
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => setState(() {
                        _rows.remove(n);
                        _removed = '$n';
                      }),
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      child: tagged(
                        Tags.swipeRow(n),
                        button: true,
                        ListTile(title: Text(Tags.swipeRowLabel(n))),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}
