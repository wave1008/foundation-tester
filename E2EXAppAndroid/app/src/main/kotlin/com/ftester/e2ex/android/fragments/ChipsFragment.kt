package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.fragment.app.Fragment
import com.ftester.e2ex.android.R
import com.google.android.material.button.MaterialButtonToggleGroup
import com.google.android.material.chip.Chip
import com.google.android.material.slider.RangeSlider
import kotlin.math.roundToInt

class ChipsFragment : Fragment(R.layout.fragment_chips) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val chipWifi = view.findViewById<Chip>(R.id.chip_wifi)
        val txtChipResult = view.findViewById<TextView>(R.id.txt_chip_result)
        val chipAssist = view.findViewById<Chip>(R.id.chip_assist)
        val txtAssistResult = view.findViewById<TextView>(R.id.txt_assist_result)
        val segGroup = view.findViewById<MaterialButtonToggleGroup>(R.id.seg_group)
        val txtSegResult = view.findViewById<TextView>(R.id.txt_seg_result)
        val rangeSlider = view.findViewById<RangeSlider>(R.id.range_slider)
        val txtRangeResult = view.findViewById<TextView>(R.id.txt_range_result)

        txtChipResult.text = "wifi=${chipWifi.isChecked}"
        chipWifi.setOnCheckedChangeListener { _, isChecked ->
            txtChipResult.text = "wifi=$isChecked"
        }

        txtAssistResult.text = "assist=none"
        chipAssist.setOnClickListener {
            txtAssistResult.text = "assist=tapped"
        }

        txtSegResult.text = "seg=day"
        segGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            txtSegResult.text = "seg=" + when (checkedId) {
                R.id.seg_day -> "day"
                R.id.seg_week -> "week"
                R.id.seg_month -> "month"
                else -> "day"
            }
        }

        fun renderRange() {
            val values = rangeSlider.values
            txtRangeResult.text = "range=${values[0].roundToInt()}-${values[1].roundToInt()}"
        }
        renderRange()
        rangeSlider.addOnChangeListener { _, _, _ -> renderRange() }
    }
}
