import 'dart:async';

import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

enum _Phase { initial, idle, footer, error, end }

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  static const _firstPage = 30;
  static const _secondPage = 20;
  // 末尾とみなす残りの px。ScrollController の maxScrollExtent に対する許容
  static const _endSlop = 24.0;

  final _scroll = ScrollController();
  _Phase _phase = _Phase.initial;
  int _loaded = 0;
  bool _failedOnce = false;
  String _result = 'none';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _startInitial();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String get _stateLabel => switch (_phase) {
    _Phase.initial || _Phase.footer => 'loading',
    _Phase.idle => 'loaded',
    _Phase.error => 'error',
    _Phase.end => 'end',
  };

  void _startInitial() {
    _timer?.cancel();
    setState(() {
      _phase = _Phase.initial;
      _loaded = 0;
      _failedOnce = false;
    });
    _timer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _loaded = _firstPage;
        _phase = _Phase.idle;
      });
    });
  }

  void _reload() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _startInitial();
  }

  void _onScroll() {
    if (_phase != _Phase.idle || !_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent - _scroll.offset > _endSlop) return;
    if (_failedOnce && _loaded >= _firstPage + _secondPage) {
      setState(() => _phase = _Phase.end);
      return;
    }
    _loadMore();
  }

  void _loadMore() {
    setState(() => _phase = _Phase.footer);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      if (!_failedOnce) {
        setState(() {
          _failedOnce = true;
          _phase = _Phase.error;
        });
      } else {
        setState(() {
          _loaded += _secondPage;
          _phase = _Phase.idle;
        });
      }
    });
  }

  Widget _skeleton(int n) => Semantics(
    identifier: Tags.rowL(n),
    label: Tags.rowLLabel(n),
    button: true,
    enabled: false,
    excludeSemantics: true,
    child: Container(
      height: 56,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );

  Widget? _footer() => switch (_phase) {
    _Phase.footer => const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: TaggedText(Tags.footerLoading, '読み込み中')),
    ),
    _Phase.error => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const TaggedText(Tags.footerError, '読み込みに失敗しました'),
          const SizedBox(height: 8),
          TaggedButton(Tags.btnRetry, '再試行', onTap: _loadMore),
        ],
      ),
    ),
    _Phase.end => const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: TaggedText(Tags.footerEnd, 'これ以上ありません')),
    ),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final skeleton = _phase == _Phase.initial;
    final footer = _footer();
    final rows = skeleton ? Tags.skeletonRows : _loaded;
    return FtScaffold(
      title: '読み込みの状態',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TaggedText(Tags.loadingState, 'state=$_stateLabel'),
                      TaggedText(Tags.loadingCount, 'loaded=$_loaded'),
                      TaggedText(Tags.loadingResult, 'loading=$_result'),
                    ],
                  ),
                ),
                TaggedButton(Tags.btnReload, '読み込み直す', onTap: _reload),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: rows + (footer == null ? 0 : 1),
              itemBuilder: (context, i) {
                if (i >= rows) return footer!;
                if (skeleton) return _skeleton(i);
                return tagged(
                  Tags.rowL(i),
                  ListTile(
                    title: Text(Tags.rowLLabel(i)),
                    onTap: () => setState(() => _result = Tags.rowL(i)),
                  ),
                  button: true,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
