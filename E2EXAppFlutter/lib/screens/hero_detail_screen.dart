import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';
import 'native_screen.dart' show heroTag;

class HeroDetailScreen extends StatelessWidget {
  const HeroDetailScreen({super.key});

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: 'Hero 詳細',
        body: ScreenColumn(children: [
          Hero(
            tag: heroTag,
            child: Container(
              width: 160,
              height: 160,
              color: Colors.indigo,
              alignment: Alignment.center,
              child: const Icon(Icons.auto_awesome, color: Colors.white, size: 64),
            ),
          ),
          const SizedBox(height: 24),
          TaggedButton(Tags.btnHeroBack, 'Hero から戻る', onTap: () => context.pop()),
        ]),
      );
}
