package com.ftester.e2ex.screens

import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DisplayMode
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.rememberDatePickerState
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
import com.ftester.e2ex.util.INITIAL_DATE_EPOCH_MILLIS
import com.ftester.e2ex.util.exposeTestTagsAsResourceId
import com.ftester.e2ex.util.formatUtcDate

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DatePickerScreen() {
    var dialogOpen by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("none") }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.DATE_RESULT, "date=$result")
        TaggedButton(Tags.BTN_OPEN_DATE, "日付を選ぶ") { dialogOpen = true }
    }

    if (dialogOpen) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = INITIAL_DATE_EPOCH_MILLIS,
            initialDisplayedMonthMillis = INITIAL_DATE_EPOCH_MILLIS,
            initialDisplayMode = DisplayMode.Picker
        )
        DatePickerDialog(
            // 別ウィンドウなのでルートの exposeTestTagsAsResourceId が効かない(契約 §全体規約)。
            modifier = Modifier.exposeTestTagsAsResourceId(),
            onDismissRequest = { dialogOpen = false; result = "cancel" },
            confirmButton = {
                TaggedButton(Tags.BTN_DATE_OK, "OK") {
                    val millis = datePickerState.selectedDateMillis
                    result = if (millis != null) formatUtcDate(millis) else "null"
                    dialogOpen = false
                }
            },
            dismissButton = {
                TaggedButton(Tags.BTN_DATE_CANCEL, "キャンセル") {
                    result = "cancel"
                    dialogOpen = false
                }
            }
        ) {
            // 日付セルは DatePicker 内部なので testTag 無し(ラベルで指す。契約 §日付ピッカー)。
            DatePicker(state = datePickerState)
        }
    }
}
