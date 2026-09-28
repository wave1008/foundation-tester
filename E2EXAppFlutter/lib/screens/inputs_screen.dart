import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tags.dart';
import '../widgets.dart';

class InputsScreen extends StatefulWidget {
  const InputsScreen({super.key});

  @override
  State<InputsScreen> createState() => _InputsScreenState();
}

class _InputsScreenState extends State<InputsScreen> {
  String _number = '';
  int _passwordLen = 0;
  int _lines = 1;
  String _focus = 'none';
  String _auto = 'none';
  String _bottom = '';

  final _secondFocus = FocusNode();

  static const _countries = ['Japan', 'Jamaica', 'Jordan'];

  String _autoTag(String country) => 'auto_opt_${country.toLowerCase()}';

  @override
  void initState() {
    super.initState();
    // 「次へ」で移った直後(2つ目が焦点を得た瞬間)だけ echo する(契約: focus=second)。
    _secondFocus.addListener(() {
      if (_secondFocus.hasFocus) setState(() => _focus = 'second');
    });
  }

  @override
  void dispose() {
    _secondFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '入力の種類',
        // echo は画面上部の固定領域にまとめる(スクロールしない・キーボードで隠れない)。
        // 欄はその下のスクロール領域に並べる。
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaggedText(Tags.numberEcho, 'number=$_number'),
                  TaggedText(Tags.passwordEcho, 'password_len=$_passwordLen'),
                  TaggedText(Tags.multilineEcho, 'lines=$_lines'),
                  TaggedText(Tags.focusEcho, 'focus=$_focus'),
                  TaggedText(Tags.autoEcho, 'auto=$_auto'),
                  TaggedText(Tags.bottomEcho, 'bottom=$_bottom'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    taggedContainer(
                      Tags.fieldNumber,
                      TextField(
                        decoration: const InputDecoration(labelText: '数量'),
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (v) => setState(() => _number = v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    taggedContainer(
                      Tags.fieldPassword,
                      TextField(
                        decoration: const InputDecoration(labelText: 'パスワード'),
                        obscureText: true,
                        onChanged: (v) => setState(() => _passwordLen = v.length),
                      ),
                    ),
                    const SizedBox(height: 12),
                    taggedContainer(
                      Tags.fieldMultiline,
                      TextField(
                        decoration: const InputDecoration(labelText: 'メモ'),
                        minLines: 3,
                        maxLines: null,
                        onChanged: (v) =>
                            setState(() => _lines = v.isEmpty ? 1 : v.split('\n').length),
                      ),
                    ),
                    const SizedBox(height: 12),
                    taggedContainer(
                      Tags.fieldFirst,
                      TextField(
                        decoration: const InputDecoration(labelText: '姓'),
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _secondFocus.requestFocus(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    taggedContainer(
                      Tags.fieldSecond,
                      TextField(
                        focusNode: _secondFocus,
                        decoration: const InputDecoration(labelText: '名'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    taggedContainer(
                      Tags.fieldAuto,
                      Autocomplete<String>(
                        optionsBuilder: (value) => _countries
                            .where((c) => c.toLowerCase().startsWith(value.text.toLowerCase())),
                        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
                            TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: const InputDecoration(labelText: '国'),
                        ),
                        onSelected: (v) => setState(() => _auto = v),
                        optionsViewBuilder: (context, onSelected, options) => Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 300),
                              child: ListView(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                children: [
                                  for (final option in options)
                                    tagged(
                                      _autoTag(option),
                                      ListTile(title: Text(option), onTap: () => onSelected(option)),
                                      button: true,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 下端の欄が画面に収まって見えてしまわないよう、キーボード出現時に隠れる
                    // 余白を確保する(契約: 「キーボードに隠れる位置」)。
                    const SizedBox(height: 240),
                    taggedContainer(
                      Tags.fieldBottom,
                      TextField(
                        decoration: const InputDecoration(labelText: '下の欄'),
                        onChanged: (v) => setState(() => _bottom = v),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
