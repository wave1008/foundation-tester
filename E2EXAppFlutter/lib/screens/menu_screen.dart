import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  String _menuResult = 'none';
  String _fruitResult = 'none';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'メニュー',
        body: ScreenColumn(children: [
          TaggedText(Tags.menuResult, 'menu=$_menuResult'),
          PopupMenuButton<String>(
            onSelected: (v) => setState(() => _menuResult = v),
            onCanceled: () => setState(() => _menuResult = 'dismissed'),
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: 'copy', child: tagged(Tags.menuItemCopy, const Text('コピー'), button: true)),
              PopupMenuItem(
                  value: 'share', child: tagged(Tags.menuItemShare, const Text('共有'), button: true)),
              PopupMenuItem(
                  value: 'delete', child: tagged(Tags.menuItemDelete, const Text('削除'), button: true)),
            ],
            child: tagged(
              Tags.btnOpenMenu,
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('メニューを開く'),
              ),
              button: true,
            ),
          ),
          const SizedBox(height: 16),
          TaggedText(Tags.fruitResult, 'fruit=$_fruitResult'),
          taggedContainer(
            Tags.fieldFruit,
            DropdownMenu<String>(
              label: const Text('果物'),
              onSelected: (v) {
                if (v != null) setState(() => _fruitResult = v);
              },
              dropdownMenuEntries: [
                DropdownMenuEntry(
                  value: 'apple',
                  label: 'りんご',
                  labelWidget: tagged(Tags.optFruitApple, const Text('りんご'), button: true),
                ),
                DropdownMenuEntry(
                  value: 'banana',
                  label: 'バナナ',
                  labelWidget: tagged(Tags.optFruitBanana, const Text('バナナ'), button: true),
                ),
                DropdownMenuEntry(
                  value: 'cherry',
                  label: 'さくらんぼ',
                  labelWidget: tagged(Tags.optFruitCherry, const Text('さくらんぼ'), button: true),
                ),
              ],
            ),
          ),
        ]),
      );
}
