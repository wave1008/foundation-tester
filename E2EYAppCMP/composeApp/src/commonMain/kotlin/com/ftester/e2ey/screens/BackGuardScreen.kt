package com.ftester.e2ey.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.backhandler.BackHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import com.ftester.e2ey.ui.BackBridge
import com.ftester.e2ey.ui.TaggedButton
import com.ftester.e2ey.ui.TaggedText
import com.ftester.e2ey.util.exposeTestTagsAsResourceId

// 編集画面 → この画面へ結果を返す(離脱で初期化: HomeScreen が none に戻す)。
object BackGuardState {
    var result by mutableStateOf("none")
}

@Composable
fun BackGuardScreen(navController: NavHostController) {
    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        TaggedText("txt_back_result", "back=${BackGuardState.result}")
        TaggedButton("btn_open_editor", "編集画面を開く") { navController.navigate(com.ftester.e2ey.Routes.EDITOR) }
    }
}

// A8: BackHandler で戻るを横取りする。パネル → 閉じるだけ / 空 → 戻る / 文字あり → 確認ダイアログ。
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun EditorScreen(navController: NavHostController) {
    var title by remember { mutableStateOf("") }
    var panelOpen by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }

    val handle by rememberUpdatedState {
        when {
            confirming -> Unit
            panelOpen -> panelOpen = false
            title.isEmpty() -> { BackGuardState.result = "clean"; navController.popBackStack() }
            else -> confirming = true
        }
    }
    BackHandler(enabled = true) { handle() }
    DisposableEffect(Unit) {
        BackBridge.handler = { handle() }
        onDispose { BackBridge.handler = null }
    }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        TaggedText("txt_editor_state", if (panelOpen) "panel=open" else "panel=closed")
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text("タイトル") },
            modifier = Modifier.fillMaxWidth().testTag("field_title")
        )
        TaggedButton("btn_open_panel", "パネルを開く") { panelOpen = true }
        if (panelOpen) {
            Column(modifier = Modifier.fillMaxWidth().padding(top = 8.dp).testTag("panel_inline")) {
                TaggedText("txt_panel", "パネル")
            }
        }
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            modifier = Modifier.exposeTestTagsAsResourceId(),
            title = { TaggedText("txt_discard_title", "変更を破棄しますか?") },
            confirmButton = {
                TextButton(
                    onClick = { confirming = false; BackGuardState.result = "discarded"; navController.popBackStack() },
                    modifier = Modifier.testTag("btn_discard")
                ) { Text("破棄") }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }, modifier = Modifier.testTag("btn_keep")) { Text("編集を続ける") }
            }
        )
    }
}
