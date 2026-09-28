package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.navigation.findNavController
import com.ftester.e2ex.android.R

class DetailFragment : Fragment(R.layout.fragment_detail) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val id = arguments?.getInt("id") ?: 1
        view.findViewById<TextView>(R.id.txt_detail_id).text = "id=$id"
        view.findViewById<View>(R.id.btn_detail_next).setOnClickListener {
            // detail/{id} は自分自身への遷移(契約 §引数付き遷移: 次の詳細を積む)。
            it.findNavController().navigate(R.id.detailFragment, bundleOf("id" to id + 1))
        }
    }
}
