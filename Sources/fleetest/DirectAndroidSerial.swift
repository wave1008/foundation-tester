// --profile 無しで Android を撃つ CLI の経路(run / api run の直接指定・api list-apps・手動駆動のサブコマンド)の宛先。
// serial 省略時は接続中の1台を採り、複数・0台は断る(素の `AndroidDriver(serial: nil)` は adb を -s 無しで撃ち、
// 複数台つながっていると "more than one device/emulator" が生で出た)。
// 判定と文言は `AndroidTargetResolution` / `AndroidSerialResolver` の1箇所。ここは `AndroidTargetError` を
// `ValidationError` へ包むだけ(`names` = その呼び手が受ける引数名: run は .cliRun・手動駆動は .cliManual)

import ArgumentParser
import FTAndroid
import FTCore

enum DirectAndroidSerial {
    static func resolve(explicit: String?, names: TargetArgumentNames) throws -> String {
        do {
            return try AndroidTargetResolution.serial(explicit: explicit, names: names, log: { ConsoleOut.err($0) })
        } catch let error as AndroidTargetError {
            throw ValidationError(error.message(names))
        }
    }
}
