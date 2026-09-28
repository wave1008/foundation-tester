package com.ftester.e2ex.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.ftester.e2ex.Tags
import com.ftester.e2ex.formatScale
import com.ftester.e2ex.ui.ScreenColumn
import com.ftester.e2ex.ui.TaggedButton
import com.ftester.e2ex.ui.TaggedText

@Composable
fun ZoomScreen() {
    var scale by remember { mutableStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        scale = (scale * zoomChange).coerceIn(Tags.ZOOM_MIN, Tags.ZOOM_MAX)
        offset += panChange
    }

    ScreenColumn(scrollable = true) {
        TaggedText(Tags.ZOOM_SCALE, "scale=${formatScale(scale)}")
        TaggedButton(Tags.BTN_ZOOM_RESET, "元に戻す") { scale = 1f; offset = Offset.Zero }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(240.dp)
                .testTag(Tags.ZOOM_TARGET)
                // 拡大した中身が枠の外へはみ出して他の UI(#txt_zoom_scale 等)を覆わないよう、
                // clipToBounds を graphicsLayer の外側に置いて未拡大時の枠で切り取る(契約 §ピンチで拡大)。
                .clipToBounds()
                .transformable(transformState)
                .graphicsLayer(
                    scaleX = scale,
                    scaleY = scale,
                    translationX = offset.x,
                    translationY = offset.y
                )
                .background(Color(0xFF6650a4))
        )
    }
}
