import { HomeChildScreen } from './navigation';

// fte2ern:// の契約表(E2EAppCMP/docs/ui-contract.md §ディープリンク)の2行だけをルーティングする。
// クエリは見ない。未知の URL は null(= 遷移しない)。Hermes に URL グローバルが無い環境でも
// 動くよう文字列操作だけで解決する(他 SUT の resolve/routeDeepLink と同じ方針)。
const SCHEME_PREFIX = 'fte2ern://';

export function resolveDeepLinkScreen(url: string): HomeChildScreen | null {
  if (!url.startsWith(SCHEME_PREFIX)) {
    return null;
  }
  const path = url.slice(SCHEME_PREFIX.length).split('?')[0];
  switch (path) {
    case 'screen/selector':
      return 'selector';
    case 'screen/lifecycle':
      return 'lifecycle';
    default:
      return null;
  }
}
