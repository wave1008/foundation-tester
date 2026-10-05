package com.ftester.e2ey.android.fragments

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ey.android.DynamicIds
import com.ftester.e2ey.android.R

private const val SHELF_COUNT = 10
private const val CARD_COUNT = 15

// A1: 縦の RecyclerView の行ごとに横の RecyclerView が入る。横の画面外のカードは仮想化で木に居ない。
class NestedFragment : Fragment(R.layout.fragment_nested) {

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val txtResult = view.findViewById<TextView>(R.id.txt_nested_result)
        txtResult.text = "nested=none"
        val pool = RecyclerView.RecycledViewPool()

        val list = view.findViewById<RecyclerView>(R.id.list_nested)
        list.layoutManager = LinearLayoutManager(requireContext())
        list.adapter = object : RecyclerView.Adapter<ShelfHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ShelfHolder {
                val v = LayoutInflater.from(parent.context).inflate(R.layout.item_shelf, parent, false)
                val h = ShelfHolder(v)
                h.shelf.layoutManager = LinearLayoutManager(parent.context, LinearLayoutManager.HORIZONTAL, false)
                h.shelf.setRecycledViewPool(pool)
                return h
            }

            override fun onBindViewHolder(holder: ShelfHolder, position: Int) {
                val ctx = holder.itemView.context
                holder.title.id = DynamicIds.of(ctx, "txt_shelf_$position")
                holder.title.text = "棚 $position"
                holder.shelf.id = DynamicIds.of(ctx, "shelf_$position")
                holder.shelf.adapter = CardAdapter(position, txtResult)
            }

            override fun getItemCount() = SHELF_COUNT
        }
    }

    private class ShelfHolder(v: View) : RecyclerView.ViewHolder(v) {
        val title: TextView = v.findViewById(R.id.txt_shelf_title)
        val shelf: RecyclerView = v.findViewById(R.id.shelf_list)
    }

    private class CardAdapter(private val shelf: Int, private val txtResult: TextView) :
        RecyclerView.Adapter<TextHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = TextHolder(
            LayoutInflater.from(parent.context).inflate(R.layout.item_card, parent, false) as TextView
        )

        override fun onBindViewHolder(holder: TextHolder, position: Int) {
            val jj = position.toString().padStart(2, '0')
            holder.text.id = DynamicIds.of(holder.text.context, "card_${shelf}_$jj")
            holder.text.text = "カード $shelf-$jj"
            holder.text.setOnClickListener { txtResult.text = "nested=card_${shelf}_$jj" }
        }

        override fun getItemCount() = CARD_COUNT
    }
}
