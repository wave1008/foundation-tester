import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class DialogsScreen extends StatefulWidget {
  const DialogsScreen({super.key});

  @override
  State<DialogsScreen> createState() => _DialogsScreenState();
}

class _DialogsScreenState extends State<DialogsScreen> {
  // #txt_dialogs_result は契約表の値そのもの("alert=ok" 等)を出す("dialogs=" は前置しない。
  // 初期値だけ dialogs=none)。
  String _result = 'dialogs=none';

  // アラート/入力つき/アクションシートのボタンは契約に #id が無い(その場で作る AlertDialog /
  // CupertinoActionSheet でも、契約が id を与えていない部品はラベルで指す前提。全体規約どおり)。

  Future<void> _showAlert() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('よろしいですか?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
        ],
      ),
    );
    setState(() => _result = 'alert=${ok == true ? 'ok' : 'cancel'}');
  }

  Future<void> _showPrompt() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        content: taggedContainer(
          Tags.fieldPrompt,
          TextField(controller: controller, autofocus: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存')),
        ],
      ),
    );
    setState(() => _result = 'prompt=${value ?? 'cancel'}');
  }

  Future<void> _showActionSheet() async {
    final value = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'camera'),
            child: const Text('写真を撮る'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context, 'library'),
            child: const Text('ライブラリから選ぶ'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context, 'cancel'),
          child: const Text('キャンセル'),
        ),
      ),
    );
    setState(() => _result = 'sheet=${value ?? 'cancel'}');
  }

  Future<void> _showFullscreen() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const TaggedText(Tags.txtFullscreenTitle, '全画面ダイアログ'),
            leading: tagged(
              Tags.btnFullscreenClose,
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '閉じる',
                onPressed: () => Navigator.pop(context, 'closed'),
              ),
              button: true,
            ),
            actions: [
              tagged(
                Tags.btnFullscreenSave,
                TextButton(onPressed: () => Navigator.pop(context, 'saved'), child: const Text('保存')),
                button: true,
              ),
            ],
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );
    setState(() => _result = 'fullscreen=${value ?? 'closed'}');
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ダイアログ',
        // #btn_toast は実装しない: Flutter に Android の Toast に相当する OS 標準 API が無い
        // (SnackBar は別部品で第1弾のスナックバー画面が既にカバーしている)。docs/ui-contract.md に記載。
        body: ScreenColumn(children: [
          TaggedText(Tags.dialogsResult, _result),
          TaggedButton(Tags.btnAlert, 'アラート', onTap: _showAlert),
          TaggedButton(Tags.btnPrompt, '入力つき', onTap: _showPrompt),
          TaggedButton(Tags.btnActionSheet, 'アクションシート', onTap: _showActionSheet),
          TaggedButton(Tags.btnFullscreen, '全画面', onTap: _showFullscreen),
        ]),
      );
}
