/// ホスト側のキーボードの待ち(type の後)。
/// **ブリッジのソース集合(BridgeDTO.swift)へ置かない**: 変えるとブリッジの版上げが要る。
public enum KeyboardWait {
    /// type の後にソフトキーボードが木に出るまで待つ上限(秒)。
    /// 根拠: 実測(M2Ultra と M1Ultra・エミュレータ 8 台並列で E2EX-CMP android を各 10 周、
    /// ImeTracker の onRequestShow→onShown、計 140 件)で中央値 0.20 秒・最大 0.89 秒。
    /// 尽きたら待ちをやめて従来どおり解決して撃つ(悪化はしない)・注記 keyboard-not-shown-after-type。
    /// `FocusWait.waitSeconds` と同じ値だが文脈が別なので流用しない(片方を変えても他方が黙って変わらない)
    public static let appearSeconds: Double = 1.5
    /// 撮り直しの間隔(秒)。根拠: 表示の中央値 0.2 秒の間に 1〜2 回見る
    public static let pollSeconds: Double = 0.15

    /// 隠れたキーボードは nil ではなく画面外(y が画面の下端以上)の矩形で申告されることがある。
    /// `StepExecutor.keyboardOnScreen` はここへ転送する(同じ判定を2つ持たない)
    public static func onScreen(_ frame: FTRect?, screen: FTRect) -> Bool {
        guard let frame, frame.height > 0 else { return false }
        return frame.y < screen.y + screen.height
    }

    /// type の後にキーボードの出現を待つか(純粋関数)。
    /// **Android だけ**: type が焦点を要求して書き込むとすぐ返り、IME の表示を待たないので、次の解決の木には
    /// まだ無く後から出てダイアログが動く(iOS の type は出現まで返らない)。
    /// 打つ前に出ていた(= 出現待ちでなく隠れ待ちの領分)・既に次の木に出ている・改行で終わる
    /// (Enter で閉じうる)ときは待たない
    static func shouldAwaitAppearance(isAndroid: Bool, before: FTRect?, after: FTRect?,
                                      screen: FTRect, typedNewline: Bool) -> Bool {
        isAndroid && !typedNewline && !onScreen(before, screen: screen) && !onScreen(after, screen: screen)
    }
}
