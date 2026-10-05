import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _items = <(String tag, String label, String route)>[
    (Tags.navNested, '入れ子スクロール', '/nested'),
    (Tags.navChat, '反転チャット', '/chat'),
    (Tags.navLoading, '読み込みの状態', '/loading'),
    (Tags.navSwipeActions, 'スワイプの操作', '/swipe_actions'),
    (Tags.navSelect, '選択モード', '/select'),
    (Tags.navLinks, '文中リンク', '/links'),
    (Tags.navPin, 'PIN と OTP', '/pin'),
    (Tags.navBackGuard, '戻るの横取り', '/back_guard'),
    (Tags.navPlayer, '引き伸ばせるシート', '/player'),
    (Tags.navHideBars, 'スクロールで隠れるバー', '/hide_bars'),
    (Tags.navTabHeader, '折りたたみヘッダとタブ', '/tab_header'),
    (Tags.navStaggered, '高さの揃わないグリッド', '/staggered'),
  ];

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: 'E2EY ホーム',
    body: ListView(
      children: [
        for (final (tag, label, route) in _items)
          tagged(
            tag,
            ListTile(title: Text(label), onTap: () => context.push(route)),
            button: true,
          ),
      ],
    ),
  );
}
