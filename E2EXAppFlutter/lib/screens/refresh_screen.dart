import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class RefreshScreen extends StatefulWidget {
  const RefreshScreen({super.key});

  @override
  State<RefreshScreen> createState() => _RefreshScreenState();
}

class _RefreshScreenState extends State<RefreshScreen> {
  int _count = 0;

  Future<void> _onRefresh() async {
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) setState(() => _count += 1);
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '引っ張って更新',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.refreshCount, 'refresh=$_count'),
            ),
            Expanded(
              child: taggedContainer(
                Tags.boxRefresh,
                RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: ListView.builder(
                    // 行数が画面に収まっても引っ張れるように常時スクロール可能にする。
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: Tags.refreshRowCount,
                    itemBuilder: (context, index) => tagged(
                      Tags.refreshRow(index),
                      SizedBox(height: 56, child: Align(alignment: Alignment.centerLeft, child: Text(Tags.refreshRowLabel(index)))),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
