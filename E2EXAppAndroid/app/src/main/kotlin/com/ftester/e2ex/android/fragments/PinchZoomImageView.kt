package com.ftester.e2ex.android.fragments

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import androidx.appcompat.widget.AppCompatImageView

private const val MIN_SCALE = 1f
private const val MAX_SCALE = 4f

// ピンチで拡大・縮小(ScaleGestureDetector)+ 簡易パン(1本指ドラッグ、拡大時のみ)。
// クリップは親の FrameLayout(#zoom_frame。clipChildren 既定 true)が担う
// (このビュー自身の transform では自分の描画範囲を超えて絵が伸びるため、切り取りは親に任せる)。
class PinchZoomImageView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : AppCompatImageView(context, attrs) {

    var onScaleChanged: ((Float) -> Unit)? = null

    private var currentScale = MIN_SCALE
    private var lastTouchX = 0f
    private var lastTouchY = 0f

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                currentScale = (currentScale * detector.scaleFactor).coerceIn(MIN_SCALE, MAX_SCALE)
                scaleX = currentScale
                scaleY = currentScale
                onScaleChanged?.invoke(currentScale)
                return true
            }
        }
    )

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                lastTouchX = event.x
                lastTouchY = event.y
            }
            MotionEvent.ACTION_MOVE -> {
                if (!scaleDetector.isInProgress && currentScale > MIN_SCALE) {
                    translationX += event.x - lastTouchX
                    translationY += event.y - lastTouchY
                }
                lastTouchX = event.x
                lastTouchY = event.y
            }
            else -> Unit
        }
        return true
    }

    fun reset() {
        currentScale = MIN_SCALE
        scaleX = MIN_SCALE
        scaleY = MIN_SCALE
        translationX = 0f
        translationY = 0f
        onScaleChanged?.invoke(currentScale)
    }
}
