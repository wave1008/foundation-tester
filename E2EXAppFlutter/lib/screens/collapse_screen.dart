import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

class CollapseScreen extends StatefulWidget {
  const CollapseScreen({super.key});

  @override
  State<CollapseScreen> createState() => _CollapseScreenState();
}

class _CollapseScreenState extends State<CollapseScreen> {
  String _result = 'none';

  @override
  Widget build(BuildContext context) => Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: 200,
              leading: context.canPop()
                  ? tagged(
                      Tags.back,
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: '戻る',
                        onPressed: () => context.pop(),
                      ),
                      button: true,
                    )
                  : null,
              // FlexibleSpaceBar は同じ title ウィジェットを展開時は大きく・縮小時は
              // 通常の AppBar タイトル位置へ animate する(#txt_collapse_header はどちらでも
              // ツリーに残る。この画面は #txt_screen_title を別に持たない)。
              flexibleSpace: FlexibleSpaceBar(
                title: const TaggedText(Tags.collapseHeader, '大きな見出し'),
              ),
              // pinned の bottom はスクロール量に関わらず常に見える位置
              // (#txt_collapse_result をここに置く理由。契約: ヘッダが縮んでも木に残る位置)。
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(32),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 4),
                    child: TaggedText(Tags.collapseResult, 'collapse=$_result'),
                  ),
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => tagged(
                  Tags.rowC(index),
                  button: true,
                  ListTile(
                    title: Text(Tags.rowCLabel(index)),
                    onTap: () => setState(() => _result = Tags.rowC(index)),
                  ),
                ),
                childCount: Tags.collapseRowCount,
              ),
            ),
          ],
        ),
      );
}
