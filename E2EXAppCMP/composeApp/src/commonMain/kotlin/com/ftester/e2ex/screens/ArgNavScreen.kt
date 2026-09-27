package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import com.ftester.e2ex.Routes
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton

@Composable
fun ArgNavScreen(navController: NavHostController) {
    ScreenColumn(scrollable = true) {
        for (n in 1..Tags.DETAIL_LINK_COUNT) {
            TaggedButton(Tags.detailLink(n), Tags.detailLinkLabel(n), modifier = Modifier.fillMaxWidth()) {
                navController.navigate(Routes.detail(n))
            }
        }
    }
}
