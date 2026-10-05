import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../tags.dart';
import '../widgets.dart';

class StaggeredScreen extends StatefulWidget {
  const StaggeredScreen({super.key});

  @override
  State<StaggeredScreen> createState() => _StaggeredScreenState();
}

class _StaggeredScreenState extends State<StaggeredScreen> {
  String _result = 'none';

  // 高さ 80〜200(決定的に揃わない)
  double _height(int i) => 80.0 + ((i * 37) % 5) * 30;

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '高さの揃わないグリッド',
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TaggedText(Tags.staggeredResult, 'stag=$_result'),
          ),
        ),
        Expanded(
          child: taggedContainer(
            Tags.gridStaggered,
            MasonryGridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: Tags.stagCount,
              itemBuilder: (context, i) => tagged(
                Tags.stag(i),
                SizedBox(
                  height: _height(i),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      onTap: () => setState(() => _result = Tags.stag(i)),
                      child: Center(child: Text(Tags.stagLabel(i))),
                    ),
                  ),
                ),
                button: true,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
