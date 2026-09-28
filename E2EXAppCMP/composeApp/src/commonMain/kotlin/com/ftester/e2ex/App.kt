package com.ftester.e2ex

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.savedstate.read
import com.ftester.e2ex.screens.AnimScreen
import com.ftester.e2ex.screens.ArgNavScreen
import com.ftester.e2ex.screens.BottomSheetScreen
import com.ftester.e2ex.screens.ChipsScreen
import com.ftester.e2ex.screens.CollapseScreen
import com.ftester.e2ex.screens.ContextScreen
import com.ftester.e2ex.screens.DatePickerScreen
import com.ftester.e2ex.screens.DetailScreen
import com.ftester.e2ex.screens.DialogsScreen
import com.ftester.e2ex.screens.DrawerScreen
import com.ftester.e2ex.screens.ExpandScreen
import com.ftester.e2ex.screens.FabScreen
import com.ftester.e2ex.screens.GridScreen
import com.ftester.e2ex.screens.HomeScreen
import com.ftester.e2ex.screens.InfiniteScreen
import com.ftester.e2ex.screens.InputsScreen
import com.ftester.e2ex.screens.MenuScreen
import com.ftester.e2ex.screens.NativeScreen
import com.ftester.e2ex.screens.PagerScreen
import com.ftester.e2ex.screens.RefreshScreen
import com.ftester.e2ex.screens.ReorderScreen
import com.ftester.e2ex.screens.SearchScreen
import com.ftester.e2ex.screens.SnackbarScreen
import com.ftester.e2ex.screens.StepperScreen
import com.ftester.e2ex.screens.StickyScreen
import com.ftester.e2ex.screens.SwipeScreen
import com.ftester.e2ex.screens.TabsScreen
import com.ftester.e2ex.screens.TimeScreen
import com.ftester.e2ex.screens.TooltipScreen
import com.ftester.e2ex.screens.ZoomScreen
import com.ftester.e2ex.ui.TaggedIconButton
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun App() {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = backStackEntry?.destination?.route
    val title = titleForRoute(currentRoute)

    MaterialTheme {
        Scaffold(
            // exposeTestTagsAsResourceId が無いと Android で #id が一切引けない(ルートで1回設定すれば
            // 子孫全体に効く。ModalBottomSheet 等の別ウィンドウは各画面側で再適用する)。
            modifier = Modifier.fillMaxSize().exposeTestTagsAsResourceId(),
            topBar = {
                TopAppBar(
                    title = { TaggedText(Tags.SCREEN_TITLE, title) },
                    navigationIcon = {
                        if (currentRoute != Routes.HOME && currentRoute != null) {
                            TaggedIconButton(Tags.BACK, "戻る", "←") {
                                navController.popBackStack()
                            }
                        }
                    }
                )
            }
        ) { padding ->
            NavHost(
                navController = navController,
                startDestination = Routes.HOME,
                modifier = Modifier.fillMaxSize().padding(padding)
            ) {
                composable(Routes.HOME) { HomeScreen(navController) }
                composable(Routes.PAGER) { PagerScreen() }
                composable(Routes.SHEET) { BottomSheetScreen() }
                composable(Routes.MENU) { MenuScreen() }
                composable(Routes.DATE) { DatePickerScreen() }
                composable(Routes.DRAWER) { DrawerScreen() }
                composable(Routes.REFRESH) { RefreshScreen() }
                composable(Routes.SNACKBAR) { SnackbarScreen() }
                composable(Routes.GRID) { GridScreen() }
                composable(Routes.SWIPE) { SwipeScreen() }
                composable(Routes.TABS) { TabsScreen() }
                composable(Routes.ANIM) { AnimScreen() }
                composable(Routes.TOOLTIP) { TooltipScreen() }
                composable(Routes.CHIPS) { ChipsScreen() }
                composable(Routes.SEARCH) { SearchScreen() }
                composable(Routes.ARG_NAV) { ArgNavScreen(navController) }
                composable(Routes.DETAIL) { entry ->
                    val id = entry.arguments?.read { getStringOrNull("id") }?.toIntOrNull() ?: 1
                    DetailScreen(id = id, navController = navController)
                }
                composable(Routes.COLLAPSE) { CollapseScreen() }
                composable(Routes.STICKY) { StickyScreen() }
                composable(Routes.TIME) { TimeScreen() }
                composable(Routes.DIALOGS) { DialogsScreen() }
                composable(Routes.CONTEXT) { ContextScreen() }
                composable(Routes.REORDER) { ReorderScreen() }
                composable(Routes.INPUTS) { InputsScreen() }
                composable(Routes.FAB) { FabScreen() }
                composable(Routes.EXPAND) { ExpandScreen() }
                composable(Routes.STEPPER) { StepperScreen() }
                composable(Routes.INFINITE) { InfiniteScreen() }
                composable(Routes.ZOOM) { ZoomScreen() }
                composable(Routes.NATIVE) { NativeScreen() }
            }
        }
    }
}
