import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

// 編集画面が戻ったときの結果を元の画面の echo へ渡す(none / clean / discarded)
final ValueNotifier<String> _backResult = ValueNotifier('none');

class BackGuardScreen extends StatelessWidget {
  const BackGuardScreen({super.key});

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '戻るの横取り',
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _backResult,
            builder: (_, v, _) => TaggedText(Tags.backResult, 'back=$v'),
          ),
          const SizedBox(height: 16),
          TaggedButton(
            Tags.btnOpenEditor,
            '編集画面を開く',
            onTap: () => context.push('/back_guard/editor'),
          ),
        ],
      ),
    ),
  );
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _title = TextEditingController();
  bool _panelOpen = false;
  bool _discarded = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaggedText(Tags.discardTitle, '変更を破棄しますか?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: tagged(Tags.btnDiscard, const Text('破棄'), button: true),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: tagged(Tags.btnKeep, const Text('編集を続ける'), button: true),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      // canPop を true に倒してから戻る(PopScope に弾かれない)
      setState(() => _discarded = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // パネルが開いている間・欄に文字がある間は戻りを横取りする。iOS では canPop=false の間
    // エッジスワイプ自体が無効になる(横取りして続きを処理することはできない)
    canPop: _discarded || (!_panelOpen && _title.text.isEmpty),
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) {
        _backResult.value = _discarded ? 'discarded' : 'clean';
        return;
      }
      if (_panelOpen) {
        setState(() => _panelOpen = false);
      } else {
        _confirmDiscard();
      }
    },
    child: FtScaffold(
      title: '編集',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TaggedText(
              Tags.editorState,
              'panel=${_panelOpen ? 'open' : 'closed'}',
            ),
            const SizedBox(height: 8),
            tagged(
              Tags.fieldTitle,
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'タイトル',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TaggedButton(
              Tags.btnOpenPanel,
              'パネルを開く',
              onTap: () => setState(() => _panelOpen = true),
            ),
            if (_panelOpen)
              taggedContainer(
                Tags.panelInline,
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(16),
                  color: Colors.black12,
                  child: const TaggedText(Tags.panelText, 'パネル'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
