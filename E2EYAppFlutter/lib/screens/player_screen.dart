import 'dart:async';

import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const _miniHeight = 64.0;
  static const _halfFraction = 0.5;
  // 止まったとみなす最後の extent 通知からの経過。DraggableScrollableSheet は停止の通知を持たない
  static const _settle = Duration(milliseconds: 250);

  final _sheet = DraggableScrollableController();
  String _state = 'collapsed';
  String _result = 'none';
  bool _playing = false;
  double _minFraction = 0.1;
  double _extent = 0.1;
  Timer? _settleTimer;

  @override
  void dispose() {
    _settleTimer?.cancel();
    _sheet.dispose();
    super.dispose();
  }

  String _classify(double e) {
    if (e <= _minFraction + 0.02) return 'collapsed';
    if (e >= 0.98) return 'expanded';
    return 'half';
  }

  bool _onSheetExtent(DraggableScrollableNotification n) {
    _extent = n.extent;
    _settleTimer?.cancel();
    _settleTimer = Timer(_settle, () {
      if (mounted) setState(() => _state = _classify(_extent));
    });
    return false;
  }

  Widget _mini() => tagged(
    Tags.miniPlayer,
    InkWell(
      onTap: () => _sheet.animateTo(
        _halfFraction,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ),
      child: SizedBox(
        height: _miniHeight,
        child: Row(
          children: [
            const SizedBox(width: 16),
            const Expanded(child: TaggedText(Tags.miniTitle, '再生中: トラック 1')),
            TextButton(
              onPressed: () => setState(() {
                _playing = !_playing;
                _result = _playing ? 'play' : 'pause';
              }),
              child: tagged(
                Tags.btnMiniPlay,
                Text(_playing ? '一時停止' : '再生'),
                button: true,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    ),
  );

  Widget _fullHeader() => SizedBox(
    height: _miniHeight,
    child: Row(
      children: [
        const SizedBox(width: 16),
        const Expanded(child: TaggedText(Tags.playerTitle, 'トラック 1')),
        tagged(
          Tags.btnPlayerCollapse,
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: '畳む',
            onPressed: () => _sheet.animateTo(
              _minFraction,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            ),
          ),
          button: true,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '引き伸ばせるシート',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TaggedText(Tags.sheetState, 'sheet=$_state'),
                TaggedText(Tags.playerResult, 'player=$_result'),
              ],
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              _minFraction = _miniHeight / box.maxHeight;
              return Stack(
                children: [
                  ListView.builder(
                    padding: const EdgeInsets.only(bottom: _miniHeight),
                    itemCount: Tags.mainRowCount,
                    itemBuilder: (context, i) => tagged(
                      Tags.rowMain(i),
                      ListTile(
                        title: Text(Tags.rowMainLabel(i)),
                        onTap: () =>
                            setState(() => _result = 'main:${Tags.rowMain(i)}'),
                      ),
                      button: true,
                    ),
                  ),
                  NotificationListener<DraggableScrollableNotification>(
                    onNotification: _onSheetExtent,
                    child: DraggableScrollableSheet(
                      controller: _sheet,
                      initialChildSize: _minFraction,
                      minChildSize: _minFraction,
                      maxChildSize: 1.0,
                      snap: true,
                      snapSizes: const [_halfFraction],
                      builder: (context, scroll) => Material(
                        elevation: 8,
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHigh,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16),
                        ),
                        child: taggedContainer(
                          Tags.listQueue,
                          CustomScrollView(
                            controller: scroll,
                            slivers: [
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _FixedHeader(
                                  _miniHeight,
                                  _state == 'collapsed'
                                      ? _mini()
                                      : _fullHeader(),
                                ),
                              ),
                              SliverList.builder(
                                itemCount: Tags.queueRowCount,
                                itemBuilder: (context, n) => tagged(
                                  Tags.queueRow(n),
                                  ListTile(
                                    title: Text(Tags.queueRowLabel(n)),
                                    onTap: () => setState(
                                      () =>
                                          _result = 'queue:${Tags.queueRow(n)}',
                                    ),
                                  ),
                                  button: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

/// 一覧を送っても貼り付く見出し(畳んだ状態でも畳むボタンが押せる)
class _FixedHeader extends SliverPersistentHeaderDelegate {
  _FixedHeader(this.height, this.child);

  final double height;
  final Widget child;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: child,
  );

  @override
  bool shouldRebuild(_FixedHeader old) => true;
}
