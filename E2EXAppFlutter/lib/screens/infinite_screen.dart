import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class InfiniteScreen extends StatefulWidget {
  const InfiniteScreen({super.key});

  @override
  State<InfiniteScreen> createState() => _InfiniteScreenState();
}

class _InfiniteScreenState extends State<InfiniteScreen> {
  int _loaded = Tags.infiniteInitialCount;
  String _result = 'none';
  bool _isLoading = false;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isLoading || _loaded >= Tags.infiniteMaxCount) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      setState(() => _isLoading = true);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        setState(() {
          _loaded = (_loaded + Tags.infinitePageSize).clamp(0, Tags.infiniteMaxCount);
          _isLoading = false;
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '無限スクロール',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.infiniteCount, 'loaded=$_loaded'),
            ),
            Expanded(
              child: taggedContainer(
                Tags.listInfinite,
                ListView.builder(
                  controller: _scrollController,
                  itemCount: _loaded + (_isLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= _loaded) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: TaggedText(Tags.txtLoading, '読み込み中'),
                      );
                    }
                    return tagged(
                      Tags.rowI(index),
                      button: true,
                      ListTile(
                        title: Text(Tags.rowILabel(index)),
                        onTap: () => setState(() => _result = Tags.rowI(index)),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TaggedText(Tags.infiniteResult, 'infinite=$_result'),
            ),
          ],
        ),
      );
}
