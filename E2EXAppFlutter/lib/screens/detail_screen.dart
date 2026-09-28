import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../tags.dart';
import '../widgets.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({required this.id, super.key});

  final int id;

  @override
  Widget build(BuildContext context) => FtScaffold(
        title: '詳細',
        body: ScreenColumn(children: [
          TaggedText(Tags.detailId, 'id=$id'),
          TaggedButton(Tags.btnDetailNext, '次の詳細', onTap: () => context.push('/detail/${id + 1}')),
        ]),
      );
}
