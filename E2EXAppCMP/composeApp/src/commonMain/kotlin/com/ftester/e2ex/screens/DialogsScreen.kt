package com.ftester.e2ex.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DialogsScreen() {
    var result by remember { mutableStateOf("dialogs=none") }
    var alertOpen by remember { mutableStateOf(false) }
    var promptOpen by remember { mutableStateOf(false) }
    var promptText by remember { mutableStateOf("") }
    var sheetOpen by remember { mutableStateOf(false) }
    var fullscreenOpen by remember { mutableStateOf(false) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val scope = rememberCoroutineScope()

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.DIALOGS_RESULT, result)
        TaggedButton(Tags.BTN_ALERT, "アラート") { alertOpen = true }
        TaggedButton(Tags.BTN_PROMPT, "入力つき") { promptText = ""; promptOpen = true }
        TaggedButton(Tags.BTN_ACTION_SHEET, "アクションシート") { sheetOpen = true }
        TaggedButton(Tags.BTN_FULLSCREEN, "全画面") { fullscreenOpen = true }
        // トーストは commonMain に定番部品が無いため実装しない(契約からの逸脱。docs/ui-contract.md 参照)。
    }

    if (alertOpen) {
        AlertDialog(
            modifier = Modifier.exposeTestTagsAsResourceId(),
            onDismissRequest = { alertOpen = false; result = "alert=cancel" },
            title = { Text("アラート") },
            text = { Text("よろしいですか?") },
            confirmButton = {
                TaggedButton(Tags.BTN_ALERT_OK, "OK") { result = "alert=ok"; alertOpen = false }
            },
            dismissButton = {
                TaggedButton(Tags.BTN_ALERT_CANCEL, "キャンセル") { result = "alert=cancel"; alertOpen = false }
            }
        )
    }

    if (promptOpen) {
        AlertDialog(
            modifier = Modifier.exposeTestTagsAsResourceId(),
            onDismissRequest = { promptOpen = false; result = "prompt=cancel" },
            title = { Text("入力つき") },
            text = {
                OutlinedTextField(
                    value = promptText,
                    onValueChange = { promptText = it },
                    modifier = Modifier.testTag(Tags.FIELD_PROMPT)
                )
            },
            confirmButton = {
                TaggedButton(Tags.BTN_PROMPT_SAVE, "保存") { result = "prompt=$promptText"; promptOpen = false }
            },
            dismissButton = {
                TaggedButton(Tags.BTN_PROMPT_CANCEL, "キャンセル") { result = "prompt=cancel"; promptOpen = false }
            }
        )
    }

    if (sheetOpen) {
        fun selectAndClose(value: String) {
            result = value
            scope.launch { sheetState.hide() }.invokeOnCompletion {
                if (!sheetState.isVisible) sheetOpen = false
            }
        }
        ModalBottomSheet(
            onDismissRequest = { result = "sheet=cancel"; sheetOpen = false },
            sheetState = sheetState,
            // 別ウィンドウなのでルートの exposeTestTagsAsResourceId が効かない(契約 §全体規約)。
            modifier = Modifier.exposeTestTagsAsResourceId()
        ) {
            Column(modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
                ListItem(
                    headlineContent = { Text("写真を撮る") },
                    modifier = Modifier.fillMaxWidth().testTag(Tags.BTN_SHEET_CAMERA)
                        .clickable { selectAndClose("sheet=camera") }
                )
                ListItem(
                    headlineContent = { Text("ライブラリから選ぶ") },
                    modifier = Modifier.fillMaxWidth().testTag(Tags.BTN_SHEET_LIBRARY)
                        .clickable { selectAndClose("sheet=library") }
                )
                ListItem(
                    headlineContent = { Text("キャンセル") },
                    modifier = Modifier.fillMaxWidth().testTag(Tags.BTN_SHEET_CANCEL)
                        .clickable { selectAndClose("sheet=cancel") }
                )
            }
        }
    }

    if (fullscreenOpen) {
        Dialog(
            onDismissRequest = { result = "fullscreen=closed"; fullscreenOpen = false },
            properties = DialogProperties(usePlatformDefaultWidth = false)
        ) {
            Surface(modifier = Modifier.fillMaxSize().exposeTestTagsAsResourceId()) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    TaggedText(Tags.FULLSCREEN_TITLE, "全画面ダイアログ")
                    TaggedButton(Tags.BTN_FULLSCREEN_SAVE, "保存") {
                        result = "fullscreen=saved"
                        fullscreenOpen = false
                    }
                    TaggedButton(Tags.BTN_FULLSCREEN_CLOSE, "閉じる") {
                        result = "fullscreen=closed"
                        fullscreenOpen = false
                    }
                }
            }
        }
    }
}
