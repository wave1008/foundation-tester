import 'package:flutter/material.dart';

import '../widgets.dart';

// 契約: E2EApp/docs/ui-contract.md「ID なし画面」。
// **この画面のウィジェットに Semantics(identifier:) を付けてはいけない**
// (方向セレクタだけで操作・検証できることを保証するための画面)。
// 行の最小高 48 と行間は帯判定(:right が隣の行のスイッチを拾わない)の余裕。
class NoIdScreen extends StatefulWidget {
  const NoIdScreen({super.key});

  @override
  State<NoIdScreen> createState() => _NoIdScreenState();
}

class _NoIdScreenState extends State<NoIdScreen> {
  bool _notify = false;
  bool _location = false;
  int _qty = 0;

  @override
  Widget build(BuildContext context) => ScreenColumn(scrollable: false, children: [
        const Text('設定'),
        _toggleRow('通知', _notify, (v) => setState(() => _notify = v)),
        Text('notify=${_notify ? 'on' : 'off'}'),
        _toggleRow('位置情報', _location, (v) => setState(() => _location = v)),
        Text('location=${_location ? 'on' : 'off'}'),
        SizedBox(
          height: 48,
          child: Row(children: [
            ElevatedButton(
              onPressed: () => setState(() => _qty = _qty > 0 ? _qty - 1 : 0),
              child: const Text('変更'),
            ),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('数量')),
            ElevatedButton(
              onPressed: () => setState(() => _qty += 1),
              child: const Text('変更'),
            ),
          ]),
        ),
        Text('qty=$_qty'),
      ]);

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) => SizedBox(
        height: 48,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Switch(value: value, onChanged: onChanged)],
        ),
      );
}
