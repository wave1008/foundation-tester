import 'package:flutter/material.dart';

// Flutter は canvas 描画なので、a11y ツリーは Semantics ウィジェットが作るノードが全て。
// `Semantics(identifier:)` は iOS = accessibilityIdentifier / Android = resource-id にマップされる。
//
// **罠1**: `Semantics(identifier:)` はそれ自体が1ノードを作り、子(Text/Button)が作るノードとは
// 別物になる。そのままだと「identifier だけのノード」と「label だけのノード」に割れて
// `#id` でタップしてもラベルが読めない。MergeSemantics で1ノードに畳んでから使う。
//
// **罠2**: `Slider` にだけは MergeSemantics を被せてはいけない。被せると iOS で
// **アプリ全体の a11y ツリーが空になる**(スナップショットが 0 要素になり、どのセレクタも
// 解決できなくなる。画面自体は正常に描画される)。Slider は increase/decrease の
// 子ノードを持つため、畳むとブリッジが読める形にならない。Slider は
// `Semantics(identifier: ...)` 単体で包む(型は `Other` になる。2026-07-23 実測)。
Widget tagged(String tag, Widget child, {bool button = false}) =>
    MergeSemantics(child: Semantics(identifier: tag, button: button, child: child));

class TaggedButton extends StatelessWidget {
  const TaggedButton(this.tag, this.label, {required this.onTap, this.fillWidth = false, super.key});

  final String tag;
  final String label;
  final VoidCallback onTap;
  final bool fillWidth;

  @override
  Widget build(BuildContext context) => tagged(
        tag,
        ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            minimumSize: Size(fillWidth ? double.infinity : 0, 48),
          ),
          child: Text(label),
        ),
      );
}

class TaggedText extends StatelessWidget {
  const TaggedText(this.tag, this.text, {super.key});

  final String tag;
  final String text;

  @override
  Widget build(BuildContext context) => tagged(tag, Text(text));
}

/// 画面本体の共通コンテナ。scrollable=false はソフトキーボード対策(入力画面)。
class ScreenColumn extends StatelessWidget {
  const ScreenColumn({required this.children, this.scrollable = true, super.key});

  final List<Widget> children;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final column = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final child in children)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
        ],
      ),
    );
    return scrollable ? SingleChildScrollView(child: column) : column;
  }
}
