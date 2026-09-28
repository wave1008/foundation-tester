package com.ftester.e2ex.android.fragments

import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.TextView
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.ftester.e2ex.android.DynamicIds
import com.ftester.e2ex.android.R
import com.google.android.material.search.SearchBar
import com.google.android.material.search.SearchView

private val CANDIDATE_WORDS = listOf("apple", "apricot", "banana")

class SearchFragment : Fragment(R.layout.fragment_search) {

    private var result = "none"

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val searchBar = view.findViewById<SearchBar>(R.id.field_search)
        val searchView = view.findViewById<SearchView>(R.id.search_view)
        val recycler = view.findViewById<RecyclerView>(R.id.recycler_suggestions)
        val txtResult = view.findViewById<TextView>(R.id.txt_search_result)

        txtResult.text = "search=$result"

        // #field_search はタップ対象の SearchBar 自身(契約の id)。SearchView が展開しても
        // SearchBar は GONE にならず木に残ったまま(Material の実装。実機で確認)なので、
        // 展開後の editText には別 id(#field_search_input)を割り当てる ——
        // 同じ id を共有すると展開中に2つの要素が同じ id を名乗ることになる。
        // 実際の入力は SearchBar タップ後にフォーカスが editText へ移るので(SearchView.show()の
        // 既定動作)、`tap("#field_search"); type(...)` はロケータ無しの type がそのまま拾う。
        searchView.setupWithSearchBar(searchBar)
        searchView.editText.id = DynamicIds.of(requireContext(), "field_search_input")
        searchView.editText.imeOptions = EditorInfo.IME_ACTION_SEARCH

        fun confirm(value: String) {
            result = value
            txtResult.text = "search=$result"
            searchView.hide()
        }

        val adapter = SuggestionAdapter { confirm(it) }
        recycler.layoutManager = LinearLayoutManager(requireContext())
        recycler.adapter = adapter
        adapter.submit(CANDIDATE_WORDS)

        searchView.editText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                val query = s?.toString().orEmpty()
                adapter.submit(CANDIDATE_WORDS.filter { it.startsWith(query, ignoreCase = true) })
            }

            override fun afterTextChanged(s: Editable?) {}
        })

        searchView.editText.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEARCH) {
                confirm(searchView.text.toString())
                true
            } else {
                false
            }
        }
    }

    private inner class SuggestionAdapter(private val onPick: (String) -> Unit) :
        RecyclerView.Adapter<SuggestionHolder>() {
        private var items = listOf<String>()

        fun submit(newItems: List<String>) {
            items = newItems
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): SuggestionHolder {
            val itemView = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_search_suggestion, parent, false)
            return SuggestionHolder(itemView)
        }

        override fun onBindViewHolder(holder: SuggestionHolder, position: Int) {
            val word = items[position]
            holder.itemView.id = DynamicIds.of(requireContext(), "suggestion_$word")
            (holder.itemView as TextView).text = word
            holder.itemView.setOnClickListener { onPick(word) }
        }

        override fun getItemCount() = items.size
    }

    private class SuggestionHolder(itemView: View) : RecyclerView.ViewHolder(itemView)
}
