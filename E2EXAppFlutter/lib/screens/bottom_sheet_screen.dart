import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class BottomSheetScreen extends StatefulWidget {
  const BottomSheetScreen({super.key});

  @override
  State<BottomSheetScreen> createState() => _BottomSheetScreenState();
}

class _BottomSheetScreenState extends State<BottomSheetScreen> {
  String _result = 'none';

  // isScrollControlled + 固定高さ(70%)を採用(DraggableScrollableSheet ではなく)。
  // 中身の30行 ListView は決まった高さの中でだけスクロールすればよく、シートの高さ自体が
  // 指の動きで伸縮しないほうがシナリオの座標・スクロール量が安定する。
  Future<void> _open() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.7,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: TaggedText(Tags.sheetTitle, 'シートの見出し'),
            ),
            Row(
              children: [
                for (var n = 1; n <= 3; n++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TaggedButton(Tags.sheetOpt(n), Tags.sheetOptLabel(n), fillWidth: true,
                          onTap: () => Navigator.of(sheetContext).pop('opt$n')),
                    ),
                  ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: Tags.sheetRowCount,
                itemBuilder: (context, index) => tagged(
                  Tags.sheetRow(index),
                  button: true,
                  ListTile(
                    title: Text(Tags.sheetRowLabel(index)),
                    onTap: () => Navigator.of(sheetContext).pop('row${index.toString().padLeft(2, '0')}'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    setState(() => _result = result ?? 'dismissed');
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ボトムシート',
        body: ScreenColumn(children: [
          TaggedText(Tags.sheetResult, 'sheet=$_result'),
          TaggedButton(Tags.btnOpenSheet, 'シートを開く', onTap: _open),
        ]),
      );
}
