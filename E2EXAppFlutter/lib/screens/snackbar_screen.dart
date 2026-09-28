import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class SnackbarScreen extends StatefulWidget {
  const SnackbarScreen({super.key});

  @override
  State<SnackbarScreen> createState() => _SnackbarScreenState();
}

class _SnackbarScreenState extends State<SnackbarScreen> {
  String _result = 'none';

  // Flutter の SnackBar に Android の Duration.LONG/SHORT 相当の列挙は無いため、
  // 契約の「約10秒」「約4秒」を明示の Duration として直書きする(docs/ui-contract.md に記載)。
  void _showLong() {
    final controller = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('削除しました'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: '元に戻す', onPressed: () => setState(() => _result = 'undo')),
      ),
    );
    controller.closed.then((reason) {
      if (reason != SnackBarClosedReason.action && mounted) {
        setState(() => _result = 'dismissed');
      }
    });
  }

  void _showShort() {
    final controller = ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('保存しました'), duration: Duration(seconds: 4)),
    );
    controller.closed.then((_) {
      if (mounted) setState(() => _result = 'short-dismissed');
    });
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'スナックバー',
        body: ScreenColumn(children: [
          TaggedText(Tags.snackbarResult, 'snackbar=$_result'),
          TaggedButton(Tags.btnShowSnackbar, 'スナックバーを出す', onTap: _showLong),
          TaggedButton(Tags.btnShowSnackbarShort, '短いスナックバー', onTap: _showShort),
        ]),
      );
}
