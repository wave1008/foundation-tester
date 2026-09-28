import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class FabScreen extends StatefulWidget {
  const FabScreen({super.key});

  @override
  State<FabScreen> createState() => _FabScreenState();
}

class _FabScreenState extends State<FabScreen> {
  String _result = 'none';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'FAB',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.fabResult, 'fab=$_result'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: Tags.fabRowCount,
                itemBuilder: (context, index) => tagged(
                  Tags.rowF(index),
                  ListTile(title: Text(Tags.rowFLabel(index))),
                ),
              ),
            ),
          ],
        ),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tagged(
              Tags.fabAdd,
              FloatingActionButton(
                heroTag: 'fab_add',
                tooltip: '追加',
                onPressed: () => setState(() => _result = 'add'),
                child: const Icon(Icons.add),
              ),
              button: true,
            ),
            const SizedBox(height: 12),
            tagged(
              Tags.fabExtended,
              FloatingActionButton.extended(
                heroTag: 'fab_extended',
                onPressed: () => setState(() => _result = 'extended'),
                icon: const Icon(Icons.create),
                label: const Text('新規作成'),
              ),
              button: true,
            ),
          ],
        ),
        bottomNavigationBar: BottomAppBar(
          child: Row(
            children: [
              tagged(
                Tags.barActionSearch,
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '検索',
                  onPressed: () => setState(() => _result = 'search'),
                ),
                button: true,
              ),
              tagged(
                Tags.barActionShare,
                IconButton(
                  icon: const Icon(Icons.share),
                  tooltip: '共有',
                  onPressed: () => setState(() => _result = 'share'),
                ),
                button: true,
              ),
            ],
          ),
        ),
      );
}
