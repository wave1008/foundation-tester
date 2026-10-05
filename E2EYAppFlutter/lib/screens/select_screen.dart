import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class SelectScreen extends StatefulWidget {
  const SelectScreen({super.key});

  @override
  State<SelectScreen> createState() => _SelectScreenState();
}

class _SelectScreenState extends State<SelectScreen> {
  final List<int> _rows = List.generate(Tags.selRowCount, (i) => i + 1);
  final Set<int> _selected = {};
  bool _selecting = false;
  String _result = 'none';

  void _exit() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _toggle(int n) => setState(
    () => _selected.contains(n) ? _selected.remove(n) : _selected.add(n),
  );

  void _deleteSelected() {
    final gone = (_selected.toList()..sort()).map(two).join(',');
    setState(() {
      _rows.removeWhere(_selected.contains);
      _result = 'deleted:$gone';
      _selecting = false;
      _selected.clear();
    });
  }

  Widget _row(int n) {
    final sel = _selected.contains(n);
    return MergeSemantics(
      child: Semantics(
        identifier: Tags.selRow(n),
        // 選択状態は標準の checked / selected として公開する(選択モードの間だけ)
        checked: _selecting ? sel : null,
        selected: _selecting ? sel : null,
        child: ListTile(
          leading: _selecting
              ? Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked)
              : null,
          title: Text(Tags.selRowLabel(n)),
          onTap: () {
            if (_selecting) {
              _toggle(n);
            } else {
              setState(() => _result = 'open:${Tags.selRow(n)}');
            }
          },
          onLongPress: () {
            if (!_selecting) {
              setState(() {
                _selecting = true;
                _selected.add(n);
              });
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '選択モード',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TaggedText(
                      Tags.selectMode,
                      'mode=${_selecting ? 'select' : 'normal'}',
                    ),
                    TaggedText(
                      Tags.selectCount,
                      'selected=${_selected.length}',
                    ),
                    TaggedText(Tags.selectResult, 'select=$_result'),
                  ],
                ),
              ),
              TaggedButton(
                Tags.btnEdit,
                _selecting ? '完了' : '編集',
                onTap: () =>
                    _selecting ? _exit() : setState(() => _selecting = true),
              ),
            ],
          ),
        ),
        // 選択モードの間だけ出るアクションバー
        if (_selecting)
          Container(
            color: Theme.of(context).colorScheme.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => _selected.addAll(_rows)),
                  child: tagged(
                    Tags.btnSelAll,
                    const Text('すべて選択'),
                    button: true,
                  ),
                ),
                TextButton(
                  onPressed: _deleteSelected,
                  child: tagged(
                    Tags.btnSelDelete,
                    const Text('削除'),
                    button: true,
                  ),
                ),
                const Spacer(),
                tagged(
                  Tags.btnSelCancel,
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'キャンセル',
                    onPressed: _exit,
                  ),
                  button: true,
                ),
              ],
            ),
          ),
        Expanded(child: ListView(children: [for (final n in _rows) _row(n)])),
      ],
    ),
  );
}
