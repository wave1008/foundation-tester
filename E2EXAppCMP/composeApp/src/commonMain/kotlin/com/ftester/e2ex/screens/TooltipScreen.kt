package com.ftester.e2ex.screens

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedIconButton
import com.ftester.e2ex.ui.TaggedText
import com.ftester.e2ex.util.exposeTestTagsAsResourceId

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TooltipScreen() {
    val tooltipState = rememberTooltipState()

    ScreenColumn(scrollable = true) {
        TooltipBox(
            positionProvider = TooltipDefaults.rememberTooltipPositionProvider(),
            tooltip = {
                // Popup = 別ウィンドウなのでルートの exposeTestTagsAsResourceId が効かない(契約 §全体規約)。
                PlainTooltip(modifier = Modifier.exposeTestTagsAsResourceId()) {
                    TaggedText(Tags.TOOLTIP_TEXT, "これはツールチップです")
                }
            },
            state = tooltipState
        ) {
            TaggedIconButton(Tags.BTN_TOOLTIP_ANCHOR, "情報", "ℹ") {}
        }
        TaggedText(Tags.TOOLTIP_STATE, "tooltip=${if (tooltipState.isVisible) "shown" else "hidden"}")
    }
}
