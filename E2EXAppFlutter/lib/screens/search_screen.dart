import 'package:flutter/material.dart';

import '../tags.dart';
import '../widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _result = 'none';

  static const _fruits = ['apple', 'apricot', 'banana'];

  String _tagFor(String fruit) => switch (fruit) {
        'apple' => Tags.suggestionApple,
        'apricot' => Tags.suggestionApricot,
        'banana' => Tags.suggestionBanana,
        _ => fruit,
      };

  final _controller = SearchController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '検索バー',
        body: ScreenColumn(children: [
          TaggedText(Tags.searchResult, 'search=$_result'),
          taggedContainer(
            Tags.fieldSearch,
            SearchAnchor.bar(
              searchController: _controller,
              barHintText: '検索',
              // 確定でビューを閉じる(閉じないと全画面の検索ビューが結果の表示を覆ったまま残る)
              onSubmitted: (value) {
                _controller.closeView(value);
                setState(() => _result = value);
              },
              suggestionsBuilder: (context, controller) {
                final query = controller.text;
                final matches = _fruits.where((f) => f.startsWith(query));
                return matches.map(
                  (f) => tagged(
                    _tagFor(f),
                    ListTile(
                      title: Text(f),
                      onTap: () {
                        controller.closeView(f);
                        setState(() => _result = f);
                      },
                    ),
                    button: true,
                  ),
                );
              },
            ),
          ),
        ]),
      );
}
