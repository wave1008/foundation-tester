package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.View
import androidx.core.os.bundleOf
import androidx.fragment.app.Fragment
import androidx.navigation.findNavController
import com.ftester.e2ex.android.R

class ArgNavFragment : Fragment(R.layout.fragment_argnav) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val links = mapOf(
            R.id.detail_link_1 to 1,
            R.id.detail_link_2 to 2,
            R.id.detail_link_3 to 3,
        )
        links.forEach { (idRes, n) ->
            view.findViewById<View>(idRes).setOnClickListener {
                it.findNavController().navigate(R.id.detailFragment, bundleOf("id" to n))
            }
        }
    }
}
