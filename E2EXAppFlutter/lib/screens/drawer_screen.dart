import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class DrawerScreen extends StatefulWidget {
  const DrawerScreen({super.key});

  @override
  State<DrawerScreen> createState() => _DrawerScreenState();
}

class _DrawerScreenState extends State<DrawerScreen> {
  String _result = 'none';
  bool _open = false;

  void _select(String value) {
    // Drawer を開くのに使った Navigator の history entry を pop で閉じる
    // (Scaffold が内部で ModalRoute.addLocalHistoryEntry を使うため、Scaffold.of() の
    // 子孫でなくても Navigator.pop(context) だけで閉じられる)。
    Navigator.pop(context);
    setState(() => _result = value);
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ドロワー',
        drawer: Drawer(
          child: ListView(
            children: [
              const DrawerHeader(child: TaggedText(Tags.drawerHeader, 'ドロワー見出し')),
              tagged(
                Tags.drawerItemInbox,
                ListTile(title: const Text('受信箱'), onTap: () => _select('inbox')),
                button: true,
              ),
              tagged(
                Tags.drawerItemSent,
                ListTile(title: const Text('送信済み'), onTap: () => _select('sent')),
                button: true,
              ),
              tagged(
                Tags.drawerItemTrash,
                ListTile(title: const Text('ゴミ箱'), onTap: () => _select('trash')),
                button: true,
              ),
            ],
          ),
        ),
        // ScaffoldState.isOpen はアニメーション完了時にこの callback で通知される
        // (契約の「アニメーション完了後の値」= drawerState.isOpen と同じ発火タイミング)。
        onDrawerChanged: (isOpen) => setState(() => _open = isOpen),
        body: Builder(
          builder: (innerContext) => ScreenColumn(children: [
            TaggedText(Tags.drawerResult, 'drawer=$_result'),
            TaggedText(Tags.drawerState, 'drawerOpen=$_open'),
            TaggedButton(Tags.btnOpenDrawer, 'ドロワーを開く',
                onTap: () => Scaffold.of(innerContext).openDrawer()),
          ]),
        ),
      );
}
