package com.ftester.e2ex.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TimeInput
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimeScreen() {
    var dialogOpen by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("none") }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.TIME_RESULT, "time=$result")
        TaggedButton(Tags.BTN_OPEN_TIME, "時刻を選ぶ") { dialogOpen = true }
    }

    if (dialogOpen) {
        var useTimeInput by remember { mutableStateOf(false) }
        val timePickerState = rememberTimePickerState(
            initialHour = Tags.TIME_INITIAL_HOUR,
            initialMinute = Tags.TIME_INITIAL_MINUTE,
            is24Hour = true
        )
        AlertDialog(
            // 別ウィンドウなのでルートの exposeTestTagsAsResourceId が効かない(契約 §全体規約)。
            modifier = Modifier.exposeTestTagsAsResourceId(),
            onDismissRequest = { dialogOpen = false; result = "cancel" },
            title = { Text("時刻を選ぶ") },
            text = {
                Column {
                    TaggedButton(
                        Tags.BTN_TIME_MODE_TOGGLE,
                        if (useTimeInput) "ダイヤルに切り替える" else "数字入力に切り替える"
                    ) { useTimeInput = !useTimeInput }
                    if (useTimeInput) {
                        TimeInput(state = timePickerState)
                    } else {
                        TimePicker(state = timePickerState)
                    }
                }
            },
            confirmButton = {
                TaggedButton(Tags.BTN_TIME_OK, "OK") {
                    val h = timePickerState.hour.toString().padStart(2, '0')
                    val m = timePickerState.minute.toString().padStart(2, '0')
                    result = "$h:$m"
                    dialogOpen = false
                }
            },
            dismissButton = {
                TaggedButton(Tags.BTN_TIME_CANCEL, "キャンセル") {
                    result = "cancel"
                    dialogOpen = false
                }
            }
        )
    }
}
