import React, { useState } from 'react';
import { Searchbar } from 'react-native-paper';

import { Tags } from '../tags';
import { EchoText, ListRow, ScreenContainer } from '../ui';

const CANDIDATES = [
  { testID: Tags.suggestionApple, key: 'apple' },
  { testID: Tags.suggestionApricot, key: 'apricot' },
  { testID: Tags.suggestionBanana, key: 'banana' },
];

export function SearchScreen() {
  const [query, setQuery] = useState('');
  const [focused, setFocused] = useState(false);
  const [result, setResult] = useState('search=none');

  // onBlur は候補タップの onPress より先に発火しうる(モバイル定番のフォーカス外れ競合)。
  // blur では候補を隠さず、確定操作(候補選択・検索キー)側だけで畳む。
  const showSuggestions = focused || query.length > 0;
  const suggestions = CANDIDATES.filter(c => c.key.startsWith(query.toLowerCase()));

  const confirm = (value: string) => {
    setResult(`search=${value}`);
    setQuery(value);
    setFocused(false);
  };

  return (
    <ScreenContainer>
      <Searchbar
        testID={Tags.fieldSearch}
        placeholder="検索"
        value={query}
        onChangeText={setQuery}
        onFocus={() => setFocused(true)}
        onSubmitEditing={() => confirm(query)}
      />
      {showSuggestions &&
        suggestions.map(c => (
          <ListRow key={c.key} testID={c.testID} label={c.key} onPress={() => confirm(c.key)} />
        ))}
      <EchoText testID={Tags.txtSearchResult}>{result}</EchoText>
    </ScreenContainer>
  );
}
