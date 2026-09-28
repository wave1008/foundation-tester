import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'tags.dart';

/// `Semantics(identifier:)` は iOS = accessibilityIdentifier / Android = resource-id に
/// マップされる。単体では「id だけのノード」と子(Text 等)の「label だけのノード」に割れるため
/// MergeSemantics で1ノードに畳む(E2EAppFlutter/lib/widgets.dart と同じ罠・同じ手当て)。
///
/// **例外**: Slider/RangeSlider は増減の子ノードを持つため、畳むと iOS の a11y ツリーが
/// アプリ全体で空になる(E2EAppFlutter で実測済みの罠)。この2つだけは呼ばず、
/// 呼び出し側で `Semantics(identifier: ...)` 単体を使う。
Widget tagged(String tag, Widget child, {bool button = false, String? label}) =>
    MergeSemantics(child: Semantics(identifier: tag, button: button, label: label, child: child));

/// スクロール容器など、子孫を個別ノードのまま残す必要がある場所用(`tagged()` は畳むので使えない)。
Widget taggedContainer(String tag, Widget child) =>
    Semantics(identifier: tag, container: true, explicitChildNodes: true, child: child);

class TaggedButton extends StatelessWidget {
  const TaggedButton(this.tag, this.label,
      {required this.onTap, this.fillWidth = false, this.enabled = true, super.key});

  final String tag;
  final String label;
  final VoidCallback onTap;
  final bool fillWidth;

  /// false でも a11y ツリーには残す(消すと isDisabled が「見つかりません」になる)。
  final bool enabled;

  @override
  Widget build(BuildContext context) => tagged(
        tag,
        ElevatedButton(
          onPressed: enabled ? onTap : null,
          style: ElevatedButton.styleFrom(minimumSize: Size(fillWidth ? double.infinity : 0, 48)),
          child: Text(label),
        ),
        button: true,
      );
}

class TaggedText extends StatelessWidget {
  const TaggedText(this.tag, this.text, {super.key});

  final String tag;
  final String text;

  @override
  Widget build(BuildContext context) => tagged(tag, Text(text));
}

/// 画面本体の共通コンテナ(縦スクロール)。
class ScreenColumn extends StatelessWidget {
  const ScreenColumn({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final child in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
          ],
        ),
      );
}

/// 15画面共通のシェル(Material3 Scaffold + AppBar)。ホームは戻るボタンを出さない
/// (= `canPop()` が false のとき leading は null。go_router の push 系遷移なら
/// システムの戻る(Android back・iOS エッジスワイプ)は Navigator の既定動作でそのまま効く)。
class FtScaffold extends StatelessWidget {
  const FtScaffold({
    required this.title,
    required this.body,
    this.drawer,
    this.onDrawerChanged,
    this.bottomNavigationBar,
    this.floatingActionButton,
    super.key,
  });

  final String title;
  final Widget body;
  final Widget? drawer;
  final void Function(bool)? onDrawerChanged;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: context.canPop()
              ? tagged(
                  Tags.back,
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '戻る',
                    onPressed: () => context.pop(),
                  ),
                  button: true,
                )
              : null,
          title: tagged(Tags.screenTitle, Text(title)),
        ),
        drawer: drawer,
        onDrawerChanged: onDrawerChanged,
        body: body,
        bottomNavigationBar: bottomNavigationBar,
        floatingActionButton: floatingActionButton,
      );
}
