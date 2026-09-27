package com.ftester.e2ex.util

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId

@OptIn(ExperimentalComposeUiApi::class)
actual fun Modifier.exposeTestTagsAsResourceId(): Modifier =
    this.semantics { testTagsAsResourceId = true }
