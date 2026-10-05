import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class NestedScreen extends StatefulWidget {
  const NestedScreen({super.key});

  @override
  State<NestedScreen> createState() => _NestedScreenState();
}

class _NestedScreenState extends State<NestedScreen> {
  String _result = 'none';

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '入れ子スクロール',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TaggedText(Tags.nestedResult, 'nested=$_result'),
          ),
        ),
        Expanded(
          child: taggedContainer(
            Tags.listNested,
            ListView.builder(
              itemCount: Tags.shelfCount,
              itemBuilder: (context, i) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TaggedText(Tags.shelfTitle(i), '棚 $i'),
                  ),
                  SizedBox(
                    height: 120,
                    child: taggedContainer(
                      Tags.shelf(i),
                      ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: Tags.cardCount,
                        itemBuilder: (context, j) => SizedBox(
                          width: 140,
                          child: tagged(
                            Tags.card(i, j),
                            Card(
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _result = Tags.card(i, j)),
                                child: Center(
                                  child: Text(Tags.cardLabel(i, j)),
                                ),
                              ),
                            ),
                            button: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
