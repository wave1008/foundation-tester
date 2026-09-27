package com.ftester.e2ex.screens

import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import kotlinx.coroutines.launch

@Composable
fun SnackbarScreen() {
    val snackbarHostState = remember { SnackbarHostState() }
    var result by remember { mutableStateOf("none") }
    val scope = rememberCoroutineScope()

    // 画面ローカルの Scaffold(契約 §スナックバー: root/screen-local はどちらでもよい)。
    Scaffold(
        modifier = Modifier,
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        ScreenColumn(scrollable = true) {
            TaggedText(Tags.SNACKBAR_RESULT, "snackbar=$result")
            TaggedButton(Tags.BTN_SHOW_SNACKBAR, "スナックバーを出す") {
                scope.launch {
                    val res = snackbarHostState.showSnackbar(
                        message = "削除しました",
                        actionLabel = "元に戻す",
                        duration = SnackbarDuration.Long
                    )
                    result = if (res == SnackbarResult.ActionPerformed) "undo" else "dismissed"
                }
            }
            TaggedButton(Tags.BTN_SHOW_SNACKBAR_SHORT, "短いスナックバー") {
                scope.launch {
                    val res = snackbarHostState.showSnackbar(
                        message = "保存しました",
                        duration = SnackbarDuration.Short
                    )
                    result = if (res == SnackbarResult.ActionPerformed) "undo" else "short-dismissed"
                }
            }
        }
    }
}
