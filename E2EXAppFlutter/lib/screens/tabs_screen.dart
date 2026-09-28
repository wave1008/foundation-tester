import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class TabsScreen extends StatefulWidget {
  const TabsScreen({super.key});

  @override
  State<TabsScreen> createState() => _TabsScreenState();
}

class _TabsScreenState extends State<TabsScreen> with TickerProviderStateMixin {
  late final _mainController = TabController(length: 3, vsync: this)..addListener(_onMainChanged);
  late final _scrollController = TabController(length: Tags.stabCount, vsync: this)
    ..addListener(_onScrollChanged);
  String _content = 'A';
  String _stabContent = '01';
  int _navIndex = 0;

  static const _mainLabels = ['A', 'B', 'C'];
  static const _navKeys = ['home', 'search', 'settings'];

  void _onMainChanged() {
    if (!_mainController.indexIsChanging) {
      setState(() => _content = _mainLabels[_mainController.index]);
    }
  }

  void _onScrollChanged() {
    if (!_scrollController.indexIsChanging) {
      setState(() => _stabContent = (_scrollController.index + 1).toString().padLeft(2, '0'));
    }
  }

  @override
  void dispose() {
    _mainController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'タブ',
        body: Column(
          children: [
            TabBar(
              controller: _mainController,
              tabs: [
                Tab(child: tagged(Tags.tabA, const Text('タブA'), button: true)),
                Tab(child: tagged(Tags.tabB, const Text('タブB'), button: true)),
                Tab(child: tagged(Tags.tabC, const Text('タブC'), button: true)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.tabContent, 'content=$_content'),
            ),
            taggedContainer(
              Tags.stabRow,
              TabBar(
                controller: _scrollController,
                isScrollable: true,
                tabs: [
                  for (var n = 1; n <= Tags.stabCount; n++)
                    Tab(child: tagged(Tags.stab(n), Text(Tags.stabLabel(n)), button: true)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.stabContent, 'scroll-tab=$_stabContent'),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.navbarResult, 'navbar=${_navKeys[_navIndex]}'),
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _navIndex,
          onDestinationSelected: (i) => setState(() => _navIndex = i),
          destinations: [
            NavigationDestination(
                icon: tagged(Tags.navbarHome, const Icon(Icons.home)), label: 'ホーム'),
            NavigationDestination(
                icon: tagged(Tags.navbarSearch, const Icon(Icons.search)), label: '探す'),
            NavigationDestination(
                icon: tagged(Tags.navbarSettings, const Icon(Icons.settings)), label: '設定'),
          ],
        ),
      );
}
