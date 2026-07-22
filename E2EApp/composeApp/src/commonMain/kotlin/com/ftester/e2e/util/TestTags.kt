package com.ftester.e2e.util

import androidx.compose.ui.Modifier

// Android は resource-id 化(#id 解決に必須)、iOS は testTag が自動で accessibilityIdentifier になるため no-op。
expect fun Modifier.exposeTestTagsAsResourceId(): Modifier
