// #id の唯一の正は E2EYAppCMP/docs/ui-contract.md。値はそこの表と byte 一致させる
// (シナリオが "#<値>" で参照するため、リネームは契約変更)。
String two(int n) => n.toString().padLeft(2, '0');

class Tags {
  // シェル
  static const screenTitle = 'txt_screen_title';
  static const back = 'btn_back';

  // ホーム
  static const navNested = 'nav_nested';
  static const navChat = 'nav_chat';
  static const navLoading = 'nav_loading';
  static const navSwipeActions = 'nav_swipe_actions';
  static const navSelect = 'nav_select';
  static const navLinks = 'nav_links';
  static const navPin = 'nav_pin';
  static const navBackGuard = 'nav_back_guard';
  static const navPlayer = 'nav_player';
  static const navHideBars = 'nav_hide_bars';
  static const navTabHeader = 'nav_tab_header';
  static const navStaggered = 'nav_staggered';

  // A1 入れ子スクロール
  static const listNested = 'list_nested';
  static const nestedResult = 'txt_nested_result';
  static const shelfCount = 10;
  static const cardCount = 15;
  static String shelfTitle(int i) => 'txt_shelf_$i';
  static String shelf(int i) => 'shelf_$i';
  static String card(int i, int j) => 'card_${i}_${two(j)}';
  static String cardLabel(int i, int j) => 'カード $i-${two(j)}';

  // A2 反転チャット
  static const chatResult = 'txt_chat_result';
  static const chatCount = 'txt_chat_count';
  static const chatPos = 'txt_chat_pos';
  static const btnIncoming = 'btn_incoming';
  static const listChat = 'list_chat';
  static const btnJumpBottom = 'btn_jump_bottom';
  static const fieldChat = 'field_chat';
  static const btnSend = 'btn_send';
  static const chatInitialCount = 60;
  static String msg(int n) => 'msg_${two(n)}';
  static String msgLabel(int n) => 'メッセージ ${two(n)}';

  // A3 読み込みの状態
  static const loadingState = 'txt_loading_state';
  static const loadingCount = 'txt_loading_count';
  static const loadingResult = 'txt_loading_result';
  static const btnReload = 'btn_reload';
  static const footerLoading = 'txt_footer_loading';
  static const footerError = 'txt_footer_error';
  static const btnRetry = 'btn_retry';
  static const footerEnd = 'txt_footer_end';
  static const skeletonRows = 8;
  static String rowL(int n) => 'row_l_${two(n)}';
  static String rowLLabel(int n) => '記事 ${two(n)}';

  // A4 スワイプの操作
  static const swipeActionsResult = 'txt_swipe_actions_result';
  static const swipeActionsCount = 'txt_swipe_actions_count';
  static const replyTarget = 'txt_reply_target';
  static const swipeRowCount = 6;
  static const replyRowCount = 3;
  static String swRow(int n) => 'sw_row_$n';
  static String swRowLabel(int n) => 'スワイプ行 $n';
  static String swArchive(int n) => 'btn_sw_archive_$n';
  static String swDelete(int n) => 'btn_sw_delete_$n';
  static String swPin(int n) => 'btn_sw_pin_$n';
  static String replyRow(int n) => 'reply_row_$n';
  static String replyRowLabel(int n) => '返信行 $n';

  // A5 選択モード
  static const selectMode = 'txt_select_mode';
  static const selectCount = 'txt_select_count';
  static const selectResult = 'txt_select_result';
  static const btnEdit = 'btn_edit';
  static const btnSelAll = 'btn_sel_all';
  static const btnSelDelete = 'btn_sel_delete';
  static const btnSelCancel = 'btn_sel_cancel';
  static const selRowCount = 20;
  static String selRow(int n) => 'sel_row_${two(n)}';
  static String selRowLabel(int n) => '項目 ${two(n)}';

  // A6 文中リンク
  static const linksResult = 'txt_links_result';
  static const terms = 'txt_terms';
  static const post = 'txt_post';
  static const rowWithLink = 'row_with_link';

  // A7 PIN と OTP
  static const otpResult = 'txt_otp_result';
  static const pinResult = 'txt_pin_result';
  static const pinLen = 'txt_pin_len';
  static const fieldOtp = 'field_otp';
  static const pinDots = 'pin_dots';
  static const keyDel = 'key_del';
  static String otpBox(int n) => 'otp_box_$n';
  static String key(int n) => 'key_$n';

  // A8 戻るの横取り
  static const backResult = 'txt_back_result';
  static const btnOpenEditor = 'btn_open_editor';
  static const fieldTitle = 'field_title';
  static const editorState = 'txt_editor_state';
  static const btnOpenPanel = 'btn_open_panel';
  static const panelInline = 'panel_inline';
  static const panelText = 'txt_panel';
  static const discardTitle = 'txt_discard_title';
  static const btnDiscard = 'btn_discard';
  static const btnKeep = 'btn_keep';

  // A9 引き伸ばせるシート
  static const sheetState = 'txt_sheet_state';
  static const playerResult = 'txt_player_result';
  static const miniPlayer = 'mini_player';
  static const miniTitle = 'txt_mini_title';
  static const btnMiniPlay = 'btn_mini_play';
  static const playerTitle = 'txt_player_title';
  static const btnPlayerCollapse = 'btn_player_collapse';
  static const listQueue = 'list_queue';
  static const mainRowCount = 40;
  static const queueRowCount = 30;
  static String rowMain(int n) => 'row_main_${two(n)}';
  static String rowMainLabel(int n) => '本文 ${two(n)}';
  static String queueRow(int n) => 'queue_row_${two(n)}';
  static String queueRowLabel(int n) => 'キュー ${two(n)}';

  // A10 スクロールで隠れるバー
  static const hideResult = 'txt_hide_result';
  static const barsState = 'txt_bars_state';
  static const barTop = 'bar_top_hiding';
  static const btnTopAction = 'btn_top_action';
  static const fabHiding = 'fab_hiding';
  static const barBottom = 'bar_bottom_hiding';
  static const btnBottomA = 'btn_bottom_a';
  static const btnBottomB = 'btn_bottom_b';
  static const hideRowCount = 60;
  static String rowH(int n) => 'row_h_${two(n)}';
  static String rowHLabel(int n) => '行 H${two(n)}';

  // A11 折りたたみヘッダとタブ
  static const tabHdrResult = 'txt_tabhdr_result';
  static const tabHdrTab = 'txt_tabhdr_tab';
  static const tabHdrHeader = 'txt_tabhdr_header';
  static const profileHeader = 'txt_profile_header';
  static const btnFollow = 'btn_follow';
  static const tabPosts = 'tab_posts';
  static const tabMedia = 'tab_media';
  static const tabLikes = 'tab_likes';
  static const tabRowCount = 40;
  static String post_(int n) => 'post_${two(n)}';
  static String media(int n) => 'media_${two(n)}';
  static String like(int n) => 'like_${two(n)}';

  // A12 高さの揃わないグリッド
  static const staggeredResult = 'txt_staggered_result';
  static const gridStaggered = 'grid_staggered';
  static const stagCount = 60;
  static String stag(int n) => 'stag_${two(n)}';
  static String stagLabel(int n) => 'タイル ${two(n)}';
}
