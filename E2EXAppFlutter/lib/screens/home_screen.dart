import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _items = <(String tag, String label, String route)>[
    (Tags.navPager, 'ページャ', '/pager'),
    (Tags.navSheet, 'ボトムシート', '/sheet'),
    (Tags.navMenu, 'メニュー', '/menu'),
    (Tags.navDate, '日付ピッカー', '/date'),
    (Tags.navDrawer, 'ドロワー', '/drawer'),
    (Tags.navRefresh, '引っ張って更新', '/refresh'),
    (Tags.navSnackbar, 'スナックバー', '/snackbar'),
    (Tags.navGrid, 'グリッド', '/grid'),
    (Tags.navSwipe, 'スワイプで削除', '/swipe'),
    (Tags.navTabs, 'タブ', '/tabs'),
    (Tags.navAnim, 'アニメーション', '/anim'),
    (Tags.navTooltip, 'ツールチップ', '/tooltip'),
    (Tags.navChips, 'チップと分割ボタン', '/chips'),
    (Tags.navSearch, '検索バー', '/search'),
    (Tags.navDetail, '引数付き遷移', '/argnav'),
    (Tags.navCollapse, '伸縮するヘッダ', '/collapse'),
    (Tags.navSticky, '貼り付く見出し', '/sticky'),
    (Tags.navTime, '時刻ピッカー', '/time'),
    (Tags.navDialogs, 'ダイアログ', '/dialogs'),
    (Tags.navContext, '長押しメニュー', '/context'),
    (Tags.navReorder, '並べ替え', '/reorder'),
    (Tags.navInputs, '入力の種類', '/inputs'),
    (Tags.navFab, 'FAB', '/fab'),
    (Tags.navExpand, '展開するリスト', '/expand'),
    (Tags.navStepper, 'ステッパーと進捗', '/stepper'),
    (Tags.navInfinite, '無限スクロール', '/infinite'),
    (Tags.navZoom, 'ピンチで拡大', '/zoom'),
    (Tags.navNative, '固有部品', '/native'),
  ];

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'E2EX ホーム',
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
