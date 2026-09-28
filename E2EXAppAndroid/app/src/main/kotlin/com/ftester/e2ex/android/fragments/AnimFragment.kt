package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.transition.Fade
import android.transition.TransitionManager
import android.view.View
import android.view.ViewGroup
import android.widget.TextSwitcher
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R

private const val VISIBILITY_ANIM_MS = 1500L

class AnimFragment : Fragment(R.layout.fragment_anim) {

    private var visible = false
    private var count = 0

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val root = view.findViewById<ViewGroup>(R.id.anim_root)
        val txtVisible = view.findViewById<TextView>(R.id.txt_anim_visible)
        val txtTarget = view.findViewById<TextView>(R.id.txt_anim_target)
        val switcher = view.findViewById<TextSwitcher>(R.id.switcher_anim_count)

        txtVisible.text = "visible=$visible"

        switcher.setFactory {
            TextView(requireContext()).apply {
                id = com.ftester.e2ex.android.DynamicIds.of(requireContext(), "txt_anim_count")
            }
        }
        switcher.inAnimation = android.view.animation.AnimationUtils.loadAnimation(requireContext(), R.anim.slide_in_up)
        switcher.outAnimation = android.view.animation.AnimationUtils.loadAnimation(requireContext(), R.anim.slide_out_up)
        switcher.setCurrentText("count=$count")

        view.findViewById<View>(R.id.btn_toggle_anim).setOnClickListener {
            visible = !visible
            txtVisible.text = "visible=$visible"
            TransitionManager.beginDelayedTransition(root, Fade().setDuration(VISIBILITY_ANIM_MS))
            txtTarget.visibility = if (visible) View.VISIBLE else View.GONE
        }

        view.findViewById<View>(R.id.btn_anim_inc).setOnClickListener {
            count++
            switcher.setText("count=$count")
        }
    }
}
