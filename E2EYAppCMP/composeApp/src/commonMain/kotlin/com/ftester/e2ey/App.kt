package com.ftester.e2ey

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
import com.ftester.e2ey.screens.BackGuardScreen
import com.ftester.e2ey.screens.ChatScreen
import com.ftester.e2ey.screens.EditorScreen
import com.ftester.e2ey.screens.HideBarsScreen
import com.ftester.e2ey.screens.HomeScreen
import com.ftester.e2ey.screens.LinksScreen
import com.ftester.e2ey.screens.LoadingScreen
import com.ftester.e2ey.screens.NestedScreen
import com.ftester.e2ey.screens.PinScreen
import com.ftester.e2ey.screens.PlayerScreen
import com.ftester.e2ey.screens.SelectScreen
import com.ftester.e2ey.screens.StaggeredScreen
import com.ftester.e2ey.screens.SwipeActionsScreen
import com.ftester.e2ey.screens.TabHeaderScreen
import com.ftester.e2ey.ui.BackBridge
import com.ftester.e2ey.ui.TaggedIconButton
import com.ftester.e2ey.ui.TaggedText
import com.ftester.e2ey.util.exposeTestTagsAsResourceId

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
                                // 戻る(#btn_back)もシステムの戻ると同じ横取りを通す(A8)。
                                val intercept = BackBridge.handler
                                if (intercept != null) intercept() else navController.popBackStack()
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
                composable(Routes.NESTED) { NestedScreen() }
                composable(Routes.CHAT) { ChatScreen() }
                composable(Routes.LOADING) { LoadingScreen() }
                composable(Routes.SWIPE_ACTIONS) { SwipeActionsScreen() }
                composable(Routes.SELECT) { SelectScreen() }
                composable(Routes.LINKS) { LinksScreen() }
                composable(Routes.PIN) { PinScreen() }
                composable(Routes.BACK_GUARD) { BackGuardScreen(navController) }
                composable(Routes.EDITOR) { EditorScreen(navController) }
                composable(Routes.PLAYER) { PlayerScreen() }
                composable(Routes.HIDE_BARS) { HideBarsScreen() }
                composable(Routes.TAB_HEADER) { TabHeaderScreen() }
                composable(Routes.STAGGERED) { StaggeredScreen() }
            }
        }
    }
}
