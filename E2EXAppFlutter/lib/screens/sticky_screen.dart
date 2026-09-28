import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class StickyScreen extends StatefulWidget {
  const StickyScreen({super.key});

  @override
  State<StickyScreen> createState() => _StickyScreenState();
}

class _StickyScreenState extends State<StickyScreen> {
  String _result = 'none';

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '貼り付く見出し',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.stickyResult, 'sticky=$_result'),
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  for (final section in Tags.stickySections)
                    // SliverMainAxisGroup で各セクションの見出しをその区間だけに pin する
                    // (SliverPersistentHeader を並べただけだと複数の見出しが積み重なって
                    // 全部貼り付いてしまう。契約: 見出しはスクロールしても上端に貼り付くが
                    // 「その区間の」見出しだけ)。
                    SliverMainAxisGroup(
                      slivers: [
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _SectionHeaderDelegate(section),
                        ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => tagged(
                              Tags.rowS(section, index),
                              button: true,
                              ListTile(
                                title: Text(Tags.rowSLabel(section, index)),
                                onTap: () =>
                                    setState(() => _result = Tags.rowS(section, index)),
                              ),
                            ),
                            childCount: Tags.stickyRowsPerSection,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  _SectionHeaderDelegate(this.section);

  final String section;
  static const _height = 40.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => Container(
        height: _height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TaggedText(Tags.hdr(section), Tags.hdrLabel(section)),
      );

  @override
  bool shouldRebuild(covariant _SectionHeaderDelegate oldDelegate) =>
      oldDelegate.section != section;
}
