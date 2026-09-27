package com.ftester.e2ex.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.ftester.e2ex.Tags
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText

private const val VISIBILITY_ANIM_MS = 1500
private const val CONTENT_ANIM_MS = 800

@Composable
fun AnimScreen() {
    var visible by remember { mutableStateOf(false) }
    var count by remember { mutableStateOf(0) }

    ScreenColumn(scrollable = true) {
        TaggedButton(Tags.BTN_TOGGLE_ANIM, "表示を切り替える") { visible = !visible }
        // visible= はボタン押下時点で切り替わる(アニメーション開始前ではなくアニメーション中から true。契約 §アニメーション)。
        TaggedText(Tags.ANIM_VISIBLE, "visible=$visible")
        AnimatedVisibility(
            visible = visible,
            enter = fadeIn(tween(VISIBILITY_ANIM_MS)) + expandVertically(tween(VISIBILITY_ANIM_MS)),
            exit = fadeOut(tween(VISIBILITY_ANIM_MS)) + shrinkVertically(tween(VISIBILITY_ANIM_MS))
        ) {
            TaggedText(Tags.ANIM_TARGET, "アニメ完了")
        }

        TaggedButton(Tags.BTN_ANIM_INC, "増やす") { count++ }
        AnimatedContent(
            targetState = count,
            transitionSpec = {
                (slideInVertically(tween(CONTENT_ANIM_MS)) { h -> h } + fadeIn(tween(CONTENT_ANIM_MS))) togetherWith
                    (slideOutVertically(tween(CONTENT_ANIM_MS)) { h -> -h } + fadeOut(tween(CONTENT_ANIM_MS)))
            }
        ) { targetCount ->
            TaggedText(Tags.ANIM_COUNT, "count=$targetCount")
        }
    }
}
