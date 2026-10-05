import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class LinksScreen extends StatefulWidget {
  const LinksScreen({super.key});

  @override
  State<LinksScreen> createState() => _LinksScreenState();
}

class _LinksScreenState extends State<LinksScreen> {
  final List<TapGestureRecognizer> _recognizers = [];
  String _result = 'none';

  TapGestureRecognizer _on(String value) {
    final r = TapGestureRecognizer()
      ..onTap = () => setState(() => _result = value);
    _recognizers.add(r);
    return r;
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TextSpan _link(String text, String value, Color color) => TextSpan(
    text: text,
    style: TextStyle(color: color, decoration: TextDecoration.underline),
    recognizer: _on(value),
  );

  @override
  Widget build(BuildContext context) {
    // build のたびに作り直すので、前回ぶんは dispose してから積み直す
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final color = Theme.of(context).colorScheme.primary;
    const base = TextStyle(fontSize: 13, color: Colors.black87);
    return FtScaffold(
      title: '文中リンク',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TaggedText(Tags.linksResult, 'link=$_result'),
            const SizedBox(height: 24),
            // 非マージの Semantics: マージするとリンクの子ノードが親へ畳まれて個別に押せなくなる
            Semantics(
              identifier: Tags.terms,
              child: Text.rich(
                TextSpan(
                  style: base,
                  children: [
                    const TextSpan(text: '続行すると'),
                    _link('利用規約', 'terms', color),
                    const TextSpan(text: 'と'),
                    _link('プライバシーポリシー', 'privacy', color),
                    const TextSpan(text: 'に同意したものとみなされます。'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Semantics(
              identifier: Tags.post,
              child: Text.rich(
                TextSpan(
                  style: base,
                  children: [
                    _link('@alice', 'mention:alice', color),
                    const TextSpan(text: ' さんが '),
                    _link('https://example.com/a', 'url', color),
                    const TextSpan(text: ' を共有しました'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Semantics(
              identifier: Tags.rowWithLink,
              container: true,
              button: true,
              child: InkWell(
                onTap: () => setState(() => _result = 'row'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 8,
                  ),
                  child: Text.rich(
                    TextSpan(
                      style: base,
                      children: [
                        const TextSpan(text: 'お知らせ: 詳細は'),
                        _link('こちら', 'inner', color),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
