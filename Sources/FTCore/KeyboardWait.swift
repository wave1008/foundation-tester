/// ホスト側のキーボードの待ち(type の後)。
/// **ブリッジのソース集合(BridgeDTO.swift)へ置かない**: 変えるとブリッジの版上げが要る。
public enum KeyboardWait {
    /// type の後にソフトキーボードが木に出るまで待つ上限(秒)。
    /// 根拠: 実測(M2Ultra と M1Ultra・エミュレータ 8 台並列で E2EX-CMP android を各 10 周、
    /// ImeTracker の onRequestShow→onShown、計 140 件)で中央値 0.20 秒・最大 0.89 秒。
    /// iOS(XCUITest)は画面の外の申告から上がりきるまで実測 0.6〜0.9 秒(E2EY-Flutter の反転チャット)で、同じ上限に収まる。
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
    /// **Android**: type が焦点を要求して書き込むとすぐ返り、IME の表示を待たないので、次の解決の木には
    /// まだ無く後から出てダイアログが動く。
    /// **iOS は「画面の外の矩形」で申告されたときだけ** —— XCUITest の /type はキーボードが出る前に返り、
    /// 0.6〜0.9 秒は画面の下(y=891・画面 874)に申告したまま、その後に上がって入力バーを動かす(実測 E2EY-Flutter の
    /// 反転チャット: 打った直後の木の下端の送信ボタンを押し、上がってきたキーボードに当たって送信が飲まれた)。
    /// 申告が無い(nil)= ハードウェアキーボード等でそもそも出ない形は待たない(毎回上限まで待つことになる)。
    /// 打つ前に出ていた(= 出現待ちでなく隠れ待ちの領分)・既に次の木に出ている・改行で終わる
    /// (Enter で閉じうる)ときは待たない
    static func shouldAwaitAppearance(isAndroid: Bool, before: FTRect?, after: FTRect?,
                                      screen: FTRect, typedNewline: Bool) -> Bool {
        guard !typedNewline, !onScreen(before, screen: screen), !onScreen(after, screen: screen) else { return false }
        return isAndroid || after != nil
    }
}
