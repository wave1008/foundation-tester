import 'dart:async';

import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class _Msg {
  const _Msg(this.n, this.text);
  final int n;
  final String text;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _rowHeight = 56.0;
  // 最下部とみなす offset の許容(px)。reverse の一覧は最下部 = offset 0
  static const _bottomSlop = 8.0;

  final _scroll = ScrollController();
  final _field = TextEditingController();
  final List<_Msg> _msgs = [
    for (var n = 0; n < Tags.chatInitialCount; n++) _Msg(n, Tags.msgLabel(n)),
  ];
  int _nextNo = Tags.chatInitialCount;
  String _result = 'none';
  bool _atBottomAtStop = true;
  bool _awayNow = false;
  Timer? _incomingTimer;

  bool get _atBottom => !_scroll.hasClients || _scroll.offset <= _bottomSlop;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final away = !_atBottom;
      if (away != _awayNow) setState(() => _awayNow = away);
    });
  }

  @override
  void dispose() {
    _incomingTimer?.cancel();
    _scroll.dispose();
    _field.dispose();
    super.dispose();
  }

  void _syncPos() {
    final at = _atBottom;
    if (at != _atBottomAtStop) setState(() => _atBottomAtStop = at);
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    if (animate) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(0);
    }
  }

  void _incoming() {
    _incomingTimer?.cancel();
    _incomingTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      final wasAtBottom = _atBottom;
      final n = _nextNo++;
      setState(() => _msgs.add(_Msg(n, '着信 ${two(n)}')));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        if (wasAtBottom) {
          _scroll.jumpTo(0);
        } else {
          // reverse の一覧は先頭側へ足すと見えている内容がずれるので、足した高さぶん送って位置を保つ
          _scroll.jumpTo(_scroll.offset + _rowHeight);
        }
        _syncPos();
      });
    });
  }

  void _send() {
    final text = _field.text;
    if (text.isEmpty) return;
    final n = _nextNo++;
    setState(() => _msgs.add(_Msg(n, text)));
    _field.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: false);
      _syncPos();
    });
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
    title: '反転チャット',
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
                    TaggedText(Tags.chatResult, 'chat=$_result'),
                    TaggedText(Tags.chatCount, 'count=${_msgs.length}'),
                    TaggedText(Tags.chatPos, 'at_bottom=$_atBottomAtStop'),
                  ],
                ),
              ),
              TaggedButton(Tags.btnIncoming, '着信', onTap: _incoming),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollEndNotification>(
                onNotification: (_) {
                  _syncPos();
                  return false;
                },
                child: taggedContainer(
                  Tags.listChat,
                  ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    itemCount: _msgs.length,
                    itemExtent: _rowHeight,
                    itemBuilder: (context, i) {
                      final m = _msgs[_msgs.length - 1 - i];
                      return tagged(
                        Tags.msg(m.n),
                        ListTile(
                          title: Text(m.text),
                          onTap: () => setState(() => _result = Tags.msg(m.n)),
                        ),
                        button: true,
                      );
                    },
                  ),
                ),
              ),
              if (_awayNow)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: TaggedButton(
                    Tags.btnJumpBottom,
                    '最新へ',
                    onTap: _scrollToBottom,
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: tagged(
                  Tags.fieldChat,
                  TextField(
                    controller: _field,
                    decoration: const InputDecoration(
                      hintText: 'メッセージを入力',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TaggedButton(Tags.btnSend, '送信', onTap: _send),
            ],
          ),
        ),
      ],
    ),
  );
}
