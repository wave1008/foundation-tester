package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R

class ZoomFragment : Fragment(R.layout.fragment_zoom) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val target = view.findViewById<PinchZoomImageView>(R.id.zoom_target)
        val txtScale = view.findViewById<TextView>(R.id.txt_zoom_scale)

        fun render(scale: Float) {
            txtScale.text = "scale=" + String.format("%.1f", scale)
        }
        render(1.0f)
        target.onScaleChanged = { render(it) }

        view.findViewById<View>(R.id.btn_zoom_reset).setOnClickListener {
            target.reset()
        }
    }
}
