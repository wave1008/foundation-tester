// ツールの annotations(MCP の tool annotations)。クライアントが承認の扱いを分けるための唯一の材料。
// **全ツールを必ずここへ載せる**(`ToolAnnotationsTests` が toolDefinitions の名前の集合と等号で照合する)。
// openWorldHint は省くと true と読まれるので、閉じたツールにも false を明示する。

extension MCPServer {

    enum ToolEffect {
        /// 端末・アプリ・ファイルを変えない(一覧・観測・文面の生成)
        case readOnly
        /// 端末の中の画面・アプリの状態を変える(タップ・入力・起動など)
        case drivesDevice
        /// 取り返しのつかない変更(アプリのデータを消す・入れ替える・run を止める)
        case destructive
        /// プロジェクトの Swift コードをビルドしてホストで実行する(サンドボックスの枠の中だが、
        /// 利用者のコードなので何をするかはツールから言えない。ft_start_run は登録済みの他の機械にも送る)
        case runsProjectCode
        /// プロジェクトの中へファイルを書く
        case writesProjectFiles
    }

    static let toolEffects: [String: ToolEffect] = [
        "ft_status": .readOnly, "ft_list_devices": .readOnly, "ft_list_apps": .readOnly,
        "ft_list_projects": .readOnly, "ft_snapshot": .readOnly, "ft_screenshot": .readOnly,
        "ft_logs": .readOnly, "ft_results": .readOnly, "ft_run_status": .readOnly,
        "ft_dsl_commands": .readOnly, "ft_doctor": .readOnly, "ft_draft_scenario": .readOnly,

        "ft_tap": .drivesDevice, "ft_double_tap": .drivesDevice, "ft_long_press": .drivesDevice,
        "ft_type": .drivesDevice, "ft_clear_input": .drivesDevice, "ft_swipe": .drivesDevice,
        "ft_drag": .drivesDevice, "ft_gesture": .drivesDevice, "ft_pinch": .drivesDevice,
        "ft_rotate": .drivesDevice, "ft_hide_keyboard": .drivesDevice, "ft_navigate": .drivesDevice,
        "ft_scroll_to": .drivesDevice, "ft_launch": .drivesDevice, "ft_terminate": .drivesDevice,
        "ft_open_url": .drivesDevice, "ft_batch": .drivesDevice,

        "ft_clear_app_data": .destructive, "ft_install": .destructive, "ft_stop_run": .destructive,

        "ft_list_scenarios": .runsProjectCode, "ft_dry_run": .runsProjectCode,
        "ft_run_scenario": .runsProjectCode, "ft_start_run": .runsProjectCode,

        "ft_capture_element": .writesProjectFiles,
    ]

    static func annotations(for effect: ToolEffect) -> [String: Any] {
        switch effect {
        case .readOnly:
            return ["readOnlyHint": true, "openWorldHint": false]
        case .drivesDevice:
            return ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
        case .destructive:
            return ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]
        case .runsProjectCode:
            return ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]
        case .writesProjectFiles:
            return ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]
        }
    }
}
