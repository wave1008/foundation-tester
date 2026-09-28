import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class PagerScreen extends StatefulWidget {
  const PagerScreen({super.key});

  @override
  State<PagerScreen> createState() => _PagerScreenState();
}

class _PagerScreenState extends State<PagerScreen> {
  final _controller = PageController();
  int _page = 0;
  String _result = 'none';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < Tags.pageCount - 1) {
      _controller.animateToPage(_page + 1,
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    }
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'ページャ',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 240,
              child: taggedContainer(
                Tags.pagerMain,
                PageView(
                  controller: _controller,
                  onPageChanged: (n) => setState(() => _page = n),
                  children: [
                    for (var n = 0; n < Tags.pageCount; n++)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TaggedText(Tags.page(n), Tags.pageLabel(n)),
                            const SizedBox(height: 8),
                            TaggedButton(Tags.pageButton(n), Tags.pageButtonLabel(n),
                                onTap: () => setState(() => _result = 'tapped $n')),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaggedText(Tags.pagerState, 'page=$_page'),
                  TaggedText(Tags.pagerResult, 'pager=$_result'),
                  const SizedBox(height: 8),
                  TaggedButton(Tags.pagerNext, '次のページ', onTap: _next),
                ],
              ),
            ),
          ],
        ),
      );
}
