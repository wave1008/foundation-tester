package com.ftester.e2e.screens

import androidx.compose.runtime.Composable
import com.ftester.e2e.AppInfo
import com.ftester.e2e.Tags
import com.ftester.e2e.ui.ScreenColumn
import com.ftester.e2e.ui.TaggedText

@Composable
fun AboutScreen() {
    ScreenColumn(scrollable = true) {
        TaggedText(Tags.TXT_ABOUT_MARKER, "E2E について")
        TaggedText(Tags.TXT_ABOUT_APP, "app=${AppInfo.APP_ID}")
        TaggedText(Tags.TXT_ABOUT_VERSION, "version=${AppInfo.VERSION}")
    }
}
