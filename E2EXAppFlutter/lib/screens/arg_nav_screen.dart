import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

class ArgNavScreen extends StatelessWidget {
  const ArgNavScreen({super.key});

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '引数付き遷移',
        body: ScreenColumn(children: [
          for (var n = 1; n <= Tags.detailLinkCount; n++)
            TaggedButton(Tags.detailLink(n), Tags.detailLinkLabel(n),
                onTap: () => context.push('/detail/$n')),
        ]),
      );
}
