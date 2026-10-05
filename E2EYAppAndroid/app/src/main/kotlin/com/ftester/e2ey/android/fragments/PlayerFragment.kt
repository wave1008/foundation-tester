package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.button.MaterialButton

// A9: 常駐の BottomSheetBehavior(COLLAPSED / HALF_EXPANDED / EXPANDED)。背面の一覧は畳まれている間も押せる。
class PlayerFragment : Fragment(R.layout.fragment_player) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtState = view.findViewById<TextView>(R.id.txt_sheet_state)
        val txtResult = view.findViewById<TextView>(R.id.txt_player_result)
        txtState.text = "sheet=collapsed"
        txtResult.text = "player=none"

        fun bindList(list: RecyclerView, count: Int, prefix: String, label: String, echoPrefix: String) {
            list.layoutManager = LinearLayoutManager(requireContext())
            list.adapter = object : RecyclerView.Adapter<TextHolder>() {
                override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = inflateRow(parent)

                override fun onBindViewHolder(holder: TextHolder, position: Int) {
                    val nn = position.toString().padStart(2, '0')
                    holder.text.id = DynamicIds.of(holder.text.context, "${prefix}_$nn")
                    holder.text.text = "$label $nn"
                    holder.text.setOnClickListener { txtResult.text = "player=$echoPrefix:${prefix}_$nn" }
                }

                override fun getItemCount() = count
            }
        }
        bindList(view.findViewById(R.id.list_main), 40, "row_main", "本文", "main")
        bindList(view.findViewById(R.id.list_queue), 30, "queue_row", "キュー", "queue")

        val behavior = BottomSheetBehavior.from(view.findViewById<View>(R.id.player_sheet))
        behavior.addBottomSheetCallback(object : BottomSheetBehavior.BottomSheetCallback() {
            override fun onStateChanged(sheet: View, newState: Int) {
                when (newState) {
                    BottomSheetBehavior.STATE_COLLAPSED -> txtState.text = "sheet=collapsed"
                    BottomSheetBehavior.STATE_HALF_EXPANDED -> txtState.text = "sheet=half"
                    BottomSheetBehavior.STATE_EXPANDED -> txtState.text = "sheet=expanded"
                }
            }

            override fun onSlide(sheet: View, slideOffset: Float) = Unit
        })

        view.findViewById<View>(R.id.mini_player).setOnClickListener {
            behavior.state = BottomSheetBehavior.STATE_HALF_EXPANDED
        }
        view.findViewById<View>(R.id.btn_player_collapse).setOnClickListener {
            behavior.state = BottomSheetBehavior.STATE_COLLAPSED
        }
        val play = view.findViewById<MaterialButton>(R.id.btn_mini_play)
        var playing = false
        play.setOnClickListener {
            playing = !playing
            play.text = if (playing) "一時停止" else "再生"
            txtResult.text = if (playing) "player=play" else "player=pause"
        }
    }
}
