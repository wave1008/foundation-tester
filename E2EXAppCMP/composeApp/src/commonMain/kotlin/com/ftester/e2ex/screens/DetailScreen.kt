package com.ftester.e2ex.screens

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import com.ftester.e2ex.Routes
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText

@Composable
fun DetailScreen(id: Int, navController: NavHostController) {
    ScreenColumn(scrollable = true) {
        TaggedText(Tags.DETAIL_ID, "id=$id")
        TaggedButton(Tags.BTN_DETAIL_NEXT, "次の詳細") {
            navController.navigate(Routes.detail(id + 1))
        }
    }
}
