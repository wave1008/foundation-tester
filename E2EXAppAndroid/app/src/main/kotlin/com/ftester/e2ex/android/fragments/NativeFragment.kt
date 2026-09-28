package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.NumberPicker
import android.widget.Spinner
import android.widget.TextView
import androidx.constraintlayout.motion.widget.MotionLayout
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R

private val SPINNER_ITEMS = listOf("A", "B", "C")

class NativeFragment : Fragment(R.layout.fragment_native) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_native_result)
        txtResult.text = "native=none"

        val spinner = view.findViewById<Spinner>(R.id.spinner_native)
        spinner.adapter = ArrayAdapter(requireContext(), android.R.layout.simple_spinner_dropdown_item, SPINNER_ITEMS)
        // Spinner は setAdapter 直後に初期位置(0)の選択が自動で走ることがあるため、
        // 最初の1回はユーザー操作でないとみなして無視する(誤って native=spinner:A を出さない)。
        var spinnerInitialized = false
        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, v: View?, position: Int, id: Long) {
                if (!spinnerInitialized) {
                    spinnerInitialized = true
                    return
                }
                txtResult.text = "native=spinner:${SPINNER_ITEMS[position]}"
            }
            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }

        val numberPicker = view.findViewById<NumberPicker>(R.id.number_picker)
        numberPicker.minValue = 0
        numberPicker.maxValue = 9
        numberPicker.setOnValueChangedListener { _, _, newVal ->
            txtResult.text = "native=number_picker:$newVal"
        }

        val motionLayout = view.findViewById<MotionLayout>(R.id.motion_layout)
        motionLayout.setTransitionListener(object : MotionLayout.TransitionListener {
            override fun onTransitionStarted(motionLayout: MotionLayout?, startId: Int, endId: Int) = Unit
            override fun onTransitionChange(motionLayout: MotionLayout?, startId: Int, endId: Int, progress: Float) = Unit
            override fun onTransitionCompleted(motionLayout: MotionLayout?, currentId: Int) {
                if (currentId == R.id.motion_end) {
                    txtResult.text = "native=motion:end"
                }
            }
            override fun onTransitionTrigger(motionLayout: MotionLayout?, triggerId: Int, positive: Boolean, progress: Float) = Unit
        })

        view.findViewById<View>(R.id.btn_motion).setOnClickListener {
            motionLayout.transitionToEnd()
        }
    }
}
