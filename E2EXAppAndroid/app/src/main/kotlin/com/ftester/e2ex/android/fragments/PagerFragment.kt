package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.widget.ViewPager2
import com.ftester.e2ex.android.R
import com.google.android.material.button.MaterialButton

private const val PAGE_COUNT = 5

private val TXT_PAGE_IDS = intArrayOf(
    R.id.txt_page_0, R.id.txt_page_1, R.id.txt_page_2, R.id.txt_page_3, R.id.txt_page_4
)
private val BTN_PAGE_IDS = intArrayOf(
    R.id.btn_page_0, R.id.btn_page_1, R.id.btn_page_2, R.id.btn_page_3, R.id.btn_page_4
)

class PagerFragment : Fragment(R.layout.fragment_pager) {

    private var result = "none"

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val pager = view.findViewById<ViewPager2>(R.id.pager_main)
        val txtState = view.findViewById<TextView>(R.id.txt_pager_state)
        val txtResult = view.findViewById<TextView>(R.id.txt_pager_result)
        val btnNext = view.findViewById<MaterialButton>(R.id.btn_pager_next)

        fun renderResult() {
            txtResult.text = "pager=$result"
        }
        renderResult()
        txtState.text = "page=0"

        pager.adapter = object : RecyclerView.Adapter<PageHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PageHolder {
                val itemView = LayoutInflater.from(parent.context)
                    .inflate(R.layout.item_pager_page, parent, false)
                return PageHolder(itemView)
            }

            override fun onBindViewHolder(holder: PageHolder, position: Int) {
                holder.text.id = TXT_PAGE_IDS[position]
                holder.text.text = "ページ $position"
                holder.button.id = BTN_PAGE_IDS[position]
                holder.button.text = "ページ $position のボタン"
                holder.button.setOnClickListener {
                    result = "tapped $position"
                    renderResult()
                }
            }

            override fun getItemCount() = PAGE_COUNT
        }

        pager.registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                txtState.text = "page=$position"
            }
        })

        btnNext.setOnClickListener {
            val next = pager.currentItem + 1
            if (next < PAGE_COUNT) pager.setCurrentItem(next, true)
        }
    }

    private class PageHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        val text: TextView = itemView.findViewById(R.id.txt_page)
        val button: MaterialButton = itemView.findViewById(R.id.btn_page)
    }
}
