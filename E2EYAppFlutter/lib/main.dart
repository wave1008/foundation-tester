import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';

import 'screens/back_guard_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/hide_bars_screen.dart';
import 'screens/home_screen.dart';
import 'screens/links_screen.dart';
import 'screens/loading_screen.dart';
import 'screens/nested_screen.dart';
import 'screens/pin_screen.dart';
import 'screens/player_screen.dart';
import 'screens/select_screen.dart';
import 'screens/staggered_screen.dart';
import 'screens/swipe_actions_screen.dart';
import 'screens/tab_header_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter の semantics ツリーは支援技術が要求したときだけ構築される。常時 ON にしないと
  // ブリッジから要素が1つも見えない(E2EAppFlutter/lib/main.dart と同じ必須初期化)。
  SemanticsBinding.instance.ensureSemantics();
  runApp(const E2EYApp());
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/nested', builder: (context, state) => const NestedScreen()),
    GoRoute(path: '/chat', builder: (context, state) => const ChatScreen()),
    GoRoute(
      path: '/loading',
      builder: (context, state) => const LoadingScreen(),
    ),
    GoRoute(
      path: '/swipe_actions',
      builder: (context, state) => const SwipeActionsScreen(),
    ),
    GoRoute(path: '/select', builder: (context, state) => const SelectScreen()),
    GoRoute(path: '/links', builder: (context, state) => const LinksScreen()),
    GoRoute(path: '/pin', builder: (context, state) => const PinScreen()),
    GoRoute(
      path: '/back_guard',
      builder: (context, state) => const BackGuardScreen(),
      routes: [
        GoRoute(
          path: 'editor',
          builder: (context, state) => const EditorScreen(),
        ),
      ],
    ),
    GoRoute(path: '/player', builder: (context, state) => const PlayerScreen()),
    GoRoute(
      path: '/hide_bars',
      builder: (context, state) => const HideBarsScreen(),
    ),
    GoRoute(
      path: '/tab_header',
      builder: (context, state) => const TabHeaderScreen(),
    ),
    GoRoute(
      path: '/staggered',
      builder: (context, state) => const StaggeredScreen(),
    ),
  ],
);

class E2EYApp extends StatelessWidget {
  const E2EYApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'FT E2EY Flutter',
    debugShowCheckedModeBanner: false,
    routerConfig: _router,
  );
}
