package com.ftester.e2ex.android.fragments

import android.animation.ValueAnimator
import android.os.Bundle
import android.view.View
import android.view.animation.LinearInterpolator
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.progressindicator.CircularProgressIndicator
import com.google.android.material.progressindicator.LinearProgressIndicator

private const val QTY_MIN = 0
private const val QTY_MAX = 10
private const val PROGRESS_DURATION_MS = 2000L

class StepperFragment : Fragment(R.layout.fragment_stepper) {

    private var qty = 1
    private var progressAnimator: ValueAnimator? = null

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtQty = view.findViewById<TextView>(R.id.txt_qty)
        val txtProgress = view.findViewById<TextView>(R.id.txt_progress)
        val progressMain = view.findViewById<LinearProgressIndicator>(R.id.progress_main)
        val spinnerBusy = view.findViewById<CircularProgressIndicator>(R.id.spinner_busy)

        fun renderQty() {
            txtQty.text = "qty=$qty"
        }
        renderQty()
        txtProgress.text = "progress=idle"

        view.findViewById<View>(R.id.btn_qty_minus).setOnClickListener {
            if (qty > QTY_MIN) qty--
            renderQty()
        }
        view.findViewById<View>(R.id.btn_qty_plus).setOnClickListener {
            if (qty < QTY_MAX) qty++
            renderQty()
        }

        view.findViewById<View>(R.id.btn_start_progress).setOnClickListener {
            if (progressAnimator?.isRunning == true) return@setOnClickListener
            txtProgress.text = "progress=running"
            progressMain.progress = 0
            spinnerBusy.visibility = View.VISIBLE
            val animator = ValueAnimator.ofInt(0, 100).apply {
                duration = PROGRESS_DURATION_MS
                interpolator = LinearInterpolator()
                addUpdateListener { progressMain.progress = it.animatedValue as Int }
                addListener(object : android.animation.AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: android.animation.Animator) {
                        spinnerBusy.visibility = View.GONE
                        txtProgress.text = "progress=done"
                    }
                })
            }
            progressAnimator = animator
            animator.start()
        }
    }

    override fun onDestroyView() {
        progressAnimator?.cancel()
        progressAnimator = null
        super.onDestroyView()
    }
}
