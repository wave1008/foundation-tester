// #id の唯一の正は E2EYAppCMP/docs/ui-contract.md。RN の testID は iOS = accessibilityIdentifier /
// Android = resource-id に自動でマップされる。
const pad2 = (n: number) => String(n).padStart(2, '0');

export const Tags = {
  screenTitle: 'txt_screen_title',

  // A1
  listNested: 'list_nested',
  txtShelf: (i: number) => `txt_shelf_${i}`,
  shelf: (i: number) => `shelf_${i}`,
  card: (i: number, j: number) => `card_${i}_${pad2(j)}`,
  txtNestedResult: 'txt_nested_result',

  // A2
  txtChatResult: 'txt_chat_result',
  txtChatCount: 'txt_chat_count',
  txtChatPos: 'txt_chat_pos',
  btnIncoming: 'btn_incoming',
  listChat: 'list_chat',
  msg: (n: number) => `msg_${pad2(n)}`,
  btnJumpBottom: 'btn_jump_bottom',
  fieldChat: 'field_chat',
  btnSend: 'btn_send',

  // A3
  txtLoadingState: 'txt_loading_state',
  txtLoadingCount: 'txt_loading_count',
  txtLoadingResult: 'txt_loading_result',
  btnReload: 'btn_reload',
  rowL: (n: number) => `row_l_${pad2(n)}`,
  txtFooterLoading: 'txt_footer_loading',
  txtFooterError: 'txt_footer_error',
  btnRetry: 'btn_retry',
  txtFooterEnd: 'txt_footer_end',

  // A4
  txtSwipeActionsResult: 'txt_swipe_actions_result',
  txtSwipeActionsCount: 'txt_swipe_actions_count',
  txtReplyTarget: 'txt_reply_target',
  swRow: (n: number) => `sw_row_${n}`,
  btnSwArchive: (n: number) => `btn_sw_archive_${n}`,
  btnSwDelete: (n: number) => `btn_sw_delete_${n}`,
  btnSwPin: (n: number) => `btn_sw_pin_${n}`,
  replyRow: (n: number) => `reply_row_${n}`,

  // A5
  txtSelectMode: 'txt_select_mode',
  txtSelectCount: 'txt_select_count',
  txtSelectResult: 'txt_select_result',
  btnEdit: 'btn_edit',
  btnSelAll: 'btn_sel_all',
  btnSelDelete: 'btn_sel_delete',
  btnSelCancel: 'btn_sel_cancel',
  selRow: (n: number) => `sel_row_${pad2(n)}`,

  // A6
  txtLinksResult: 'txt_links_result',
  txtTerms: 'txt_terms',
  txtPost: 'txt_post',
  rowWithLink: 'row_with_link',

  // A7
  txtOtpResult: 'txt_otp_result',
  txtPinResult: 'txt_pin_result',
  txtPinLen: 'txt_pin_len',
  otpBox: (n: number) => `otp_box_${n}`,
  fieldOtp: 'field_otp',
  pinDots: 'pin_dots',
  key: (n: number) => `key_${n}`,
  keyDel: 'key_del',

  // A8
  txtBackResult: 'txt_back_result',
  btnOpenEditor: 'btn_open_editor',
  fieldTitle: 'field_title',
  txtEditorState: 'txt_editor_state',
  btnOpenPanel: 'btn_open_panel',
  panelInline: 'panel_inline',
  txtPanel: 'txt_panel',
  txtDiscardTitle: 'txt_discard_title',
  btnDiscard: 'btn_discard',
  btnKeep: 'btn_keep',

  // A9
  txtSheetState: 'txt_sheet_state',
  txtPlayerResult: 'txt_player_result',
  rowMain: (n: number) => `row_main_${pad2(n)}`,
  miniPlayer: 'mini_player',
  txtMiniTitle: 'txt_mini_title',
  btnMiniPlay: 'btn_mini_play',
  txtPlayerTitle: 'txt_player_title',
  btnPlayerCollapse: 'btn_player_collapse',
  listQueue: 'list_queue',
  queueRow: (n: number) => `queue_row_${pad2(n)}`,

  // A10
  txtHideResult: 'txt_hide_result',
  txtBarsState: 'txt_bars_state',
  barTopHiding: 'bar_top_hiding',
  btnTopAction: 'btn_top_action',
  rowH: (n: number) => `row_h_${pad2(n)}`,
  fabHiding: 'fab_hiding',
  barBottomHiding: 'bar_bottom_hiding',
  btnBottomA: 'btn_bottom_a',
  btnBottomB: 'btn_bottom_b',

  // A11
  txtTabhdrResult: 'txt_tabhdr_result',
  txtTabhdrTab: 'txt_tabhdr_tab',
  txtTabhdrHeader: 'txt_tabhdr_header',
  txtProfileHeader: 'txt_profile_header',
  btnFollow: 'btn_follow',
  tab: (name: string) => `tab_${name}`,
  item: (prefix: string, n: number) => `${prefix}_${pad2(n)}`,

  // A12
  txtStaggeredResult: 'txt_staggered_result',
  gridStaggered: 'grid_staggered',
  stag: (n: number) => `stag_${pad2(n)}`,
};
