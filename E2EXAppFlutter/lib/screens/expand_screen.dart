import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class ExpandScreen extends StatefulWidget {
  const ExpandScreen({super.key});

  @override
  State<ExpandScreen> createState() => _ExpandScreenState();
}

class _ExpandScreenState extends State<ExpandScreen> {
  String _result = 'none';

  // グループの id は ExpansionTile 全体ではなく title だけに付ける。全体に付けると
  // MergeSemantics が開いた子(#item_* )まで1ノードに畳んでタップ対象を壊す。
  Widget _group(String tag, String title, List<String> items, String Function(int) itemTag) =>
      ExpansionTile(
        title: tagged(tag, Text(title), button: true),
        children: [
          for (var i = 0; i < items.length; i++)
            tagged(
              itemTag(i + 1),
              ListTile(
                title: Text(items[i]),
                onTap: () => setState(() => _result = itemTag(i + 1)),
              ),
              button: true,
            ),
        ],
      );

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '展開するリスト',
        body: ScreenColumn(children: [
          TaggedText(Tags.expandResult, 'expand=$_result'),
          _group(Tags.groupFruit, '果物', Tags.fruitItems, Tags.itemFruit),
          _group(Tags.groupVeg, '野菜', Tags.vegItems, Tags.itemVeg),
          _group(Tags.groupDrink, '飲み物', Tags.drinkItems, Tags.itemDrink),
        ]),
      );
}
