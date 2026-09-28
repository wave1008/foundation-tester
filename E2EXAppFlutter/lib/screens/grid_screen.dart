import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class GridScreen extends StatefulWidget {
  const GridScreen({super.key});

  @override
  State<GridScreen> createState() => _GridScreenState();
}

class _GridScreenState extends State<GridScreen> {
  String _result = 'none';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'グリッド',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.gridResult, 'grid=$_result'),
            ),
            Expanded(
              child: taggedContainer(
                Tags.gridMain,
                GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3),
                  itemCount: Tags.gridCellCount,
                  itemBuilder: (context, index) => tagged(
                    Tags.cell(index),
                    button: true,
                    InkWell(
                      onTap: () => setState(() => _result = index.toString().padLeft(2, '0')),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
                        child: Text(Tags.cellLabel(index)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
