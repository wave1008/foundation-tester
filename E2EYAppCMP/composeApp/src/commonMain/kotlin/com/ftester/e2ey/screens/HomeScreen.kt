package com.ftester.e2ey.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ListItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.navigation.NavHostController
import com.ftester.e2ey.Routes
import com.ftester.e2ey.titleForRoute

private val HOME_ROWS = listOf(
    "nav_nested" to Routes.NESTED,
    "nav_chat" to Routes.CHAT,
    "nav_loading" to Routes.LOADING,
    "nav_swipe_actions" to Routes.SWIPE_ACTIONS,
    "nav_select" to Routes.SELECT,
    "nav_links" to Routes.LINKS,
    "nav_pin" to Routes.PIN,
    "nav_back_guard" to Routes.BACK_GUARD,
    "nav_player" to Routes.PLAYER,
    "nav_hide_bars" to Routes.HIDE_BARS,
    "nav_tab_header" to Routes.TAB_HEADER,
    "nav_staggered" to Routes.STAGGERED,
)

@Composable
fun HomeScreen(navController: NavHostController) {
    LaunchedEffect(Unit) { BackGuardState.result = "none" }
    LazyColumn {
        items(HOME_ROWS) { (tag, route) ->
            ListItem(
                headlineContent = { Text(titleForRoute(route)) },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(tag)
                    .clickable { navController.navigate(route) }
            )
        }
    }
}
