import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class TabHeaderScreen extends StatefulWidget {
  const TabHeaderScreen({super.key});

  @override
  State<TabHeaderScreen> createState() => _TabHeaderScreenState();
}

class _TabHeaderScreenState extends State<TabHeaderScreen>
    with SingleTickerProviderStateMixin {
  static const _names = ['posts', 'media', 'likes'];
  static const _headerHeight = 200.0;
  static const _tabBarHeight = kTextTabBarHeight;

  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(_onTab);
  final _outer = ScrollController();
  String _result = 'none';
  String _tab = 'posts';
  String _header = 'expanded';

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    final t = _names[_tabs.index];
    if (t != _tab) setState(() => _tab = t);
  }

  bool _onScrollEnd(ScrollEndNotification n) {
    if (!_outer.hasClients) return false;
    // ヘッダの見える部分(= 全体 - 貼り付く toolbar と tab bar)が尽きたら collapsed
    final collapseExtent =
        _headerHeight + _tabBarHeight - kToolbarHeight - _tabBarHeight;
    final v = _outer.offset >= collapseExtent - 0.5 ? 'collapsed' : 'expanded';
    if (v != _header) setState(() => _header = v);
    return false;
  }

  @override
  void dispose() {
    _tabs.dispose();
    _outer.dispose();
    super.dispose();
  }

  Widget _page(
    String name,
    String Function(int) idOf,
    String prefix,
    String label,
  ) => Builder(
    builder: (context) => CustomScrollView(
      key: PageStorageKey(name),
      slivers: [
        SliverOverlapInjector(
          handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
        ),
        SliverList.builder(
          itemCount: Tags.tabRowCount,
          itemBuilder: (context, i) => tagged(
            idOf(i),
            ListTile(
              title: Text('$prefix ${two(i)}'),
              onTap: () => setState(() => _result = idOf(i)),
            ),
            button: true,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '折りたたみヘッダとタブ',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TaggedText(Tags.tabHdrResult, 'tabhdr=$_result'),
                TaggedText(Tags.tabHdrTab, 'tab=$_tab'),
                TaggedText(Tags.tabHdrHeader, 'header=$_header'),
              ],
            ),
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollEndNotification>(
            onNotification: _onScrollEnd,
            child: NestedScrollView(
              controller: _outer,
              headerSliverBuilder: (context, inner) => [
                SliverOverlapAbsorber(
                  handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                    context,
                  ),
                  sliver: SliverAppBar(
                    pinned: true,
                    automaticallyImplyLeading: false,
                    expandedHeight: _headerHeight + _tabBarHeight,
                    flexibleSpace: FlexibleSpaceBar(
                      collapseMode: CollapseMode.pin,
                      background: Padding(
                        padding: const EdgeInsets.only(
                          top: kToolbarHeight,
                          bottom: _tabBarHeight,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const TaggedText(Tags.profileHeader, 'プロフィール見出し'),
                            const SizedBox(height: 8),
                            TaggedButton(
                              Tags.btnFollow,
                              'フォロー',
                              onTap: () => setState(() => _result = 'follow'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    bottom: TabBar(
                      controller: _tabs,
                      tabs: [
                        Tab(
                          child: tagged(
                            Tags.tabPosts,
                            const Text('投稿'),
                            button: true,
                          ),
                        ),
                        Tab(
                          child: tagged(
                            Tags.tabMedia,
                            const Text('メディア'),
                            button: true,
                          ),
                        ),
                        Tab(
                          child: tagged(
                            Tags.tabLikes,
                            const Text('いいね'),
                            button: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              body: TabBarView(
                controller: _tabs,
                children: [
                  _page('posts', Tags.post_, '投稿', '投稿'),
                  _page('media', Tags.media, 'メディア', 'メディア'),
                  _page('likes', Tags.like, 'いいね', 'いいね'),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
