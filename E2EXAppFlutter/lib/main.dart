import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';

import 'screens/anim_screen.dart';
import 'screens/arg_nav_screen.dart';
import 'screens/bottom_sheet_screen.dart';
import 'screens/chips_screen.dart';
import 'screens/collapse_screen.dart';
import 'screens/context_screen.dart';
import 'screens/date_picker_screen.dart';
import 'screens/detail_screen.dart';
import 'screens/dialogs_screen.dart';
import 'screens/drawer_screen.dart';
import 'screens/expand_screen.dart';
import 'screens/fab_screen.dart';
import 'screens/grid_screen.dart';
import 'screens/hero_detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/infinite_screen.dart';
import 'screens/inputs_screen.dart';
import 'screens/menu_screen.dart';
import 'screens/native_screen.dart';
import 'screens/pager_screen.dart';
import 'screens/refresh_screen.dart';
import 'screens/reorder_screen.dart';
import 'screens/search_screen.dart';
import 'screens/snackbar_screen.dart';
import 'screens/stepper_screen.dart';
import 'screens/sticky_screen.dart';
import 'screens/swipe_screen.dart';
import 'screens/tabs_screen.dart';
import 'screens/time_screen.dart';
import 'screens/tooltip_screen.dart';
import 'screens/zoom_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter の semantics ツリーは支援技術が要求したときだけ構築される。常時 ON にしないと
  // ブリッジから要素が1つも見えない(E2EAppFlutter/lib/main.dart と同じ必須初期化)。
  SemanticsBinding.instance.ensureSemantics();
  runApp(const E2EXApp());
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/pager', builder: (context, state) => const PagerScreen()),
    GoRoute(path: '/sheet', builder: (context, state) => const BottomSheetScreen()),
    GoRoute(path: '/menu', builder: (context, state) => const MenuScreen()),
    GoRoute(path: '/date', builder: (context, state) => const DatePickerScreen()),
    GoRoute(path: '/drawer', builder: (context, state) => const DrawerScreen()),
    GoRoute(path: '/refresh', builder: (context, state) => const RefreshScreen()),
    GoRoute(path: '/snackbar', builder: (context, state) => const SnackbarScreen()),
    GoRoute(path: '/grid', builder: (context, state) => const GridScreen()),
    GoRoute(path: '/swipe', builder: (context, state) => const SwipeScreen()),
    GoRoute(path: '/tabs', builder: (context, state) => const TabsScreen()),
    GoRoute(path: '/anim', builder: (context, state) => const AnimScreen()),
    GoRoute(path: '/tooltip', builder: (context, state) => const TooltipScreen()),
    GoRoute(path: '/chips', builder: (context, state) => const ChipsScreen()),
    GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
    GoRoute(path: '/argnav', builder: (context, state) => const ArgNavScreen()),
    GoRoute(
      path: '/detail/:id',
      builder: (context, state) => DetailScreen(id: int.parse(state.pathParameters['id']!)),
    ),
    GoRoute(path: '/collapse', builder: (context, state) => const CollapseScreen()),
    GoRoute(path: '/sticky', builder: (context, state) => const StickyScreen()),
    GoRoute(path: '/time', builder: (context, state) => const TimeScreen()),
    GoRoute(path: '/dialogs', builder: (context, state) => const DialogsScreen()),
    GoRoute(path: '/context', builder: (context, state) => const ContextScreen()),
    GoRoute(path: '/reorder', builder: (context, state) => const ReorderScreen()),
    GoRoute(path: '/inputs', builder: (context, state) => const InputsScreen()),
    GoRoute(path: '/fab', builder: (context, state) => const FabScreen()),
    GoRoute(path: '/expand', builder: (context, state) => const ExpandScreen()),
    GoRoute(path: '/stepper', builder: (context, state) => const StepperScreen()),
    GoRoute(path: '/infinite', builder: (context, state) => const InfiniteScreen()),
    GoRoute(path: '/zoom', builder: (context, state) => const ZoomScreen()),
    GoRoute(path: '/native', builder: (context, state) => const NativeScreen()),
    GoRoute(path: '/native/hero', builder: (context, state) => const HeroDetailScreen()),
  ],
);

class E2EXApp extends StatelessWidget {
  const E2EXApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'FT E2EX Flutter',
        debugShowCheckedModeBanner: false,
        routerConfig: _router,
      );
}
