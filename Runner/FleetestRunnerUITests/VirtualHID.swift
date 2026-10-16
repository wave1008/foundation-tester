// ランナーのプロセスに仮想 HID サービスを作り、Simulator へ HID イベントを流す(**Simulator だけ**。実機では作れない)。
// 公開 API で届かない2つに使う:
// - **折りたたみの iPhone(Duo)のヒンジ角**(POST /hinge)。simctl・devicectl・XCUIDevice のどれにも開閉の口が無い
//   (Xcode 27.2 beta 3)ので、DeviceHub の開閉ボタンと同じベンダー定義イベントを送る: usage page 0xFF61 / usage 0x5B、
//   中身は IOCFSerialize した {source: "hinge-slider-control", type: "range", value: 度} → シミュレータ内の locationd が
//   ヒンジ角として読み、SpringBoard が表示する画面を切り替える。形の出典は第三者の公開調査(duoctl / duo-fold-control /
//   auto-mobile)。切り替わったかはホストの FoldControl が devicectl で確かめる
// - **ホームボタン**(handleHome の救済)。Duo の Simulator は `XCUIDevice.press(.home)` が効かない(設定アプリでも前面の
//   まま・2026-10-16 実測)が、Consumer Control(0x0C)の Menu(0x40)のキーを押すとホームへ出る
// **非公開の形なので Xcode の版で黙って効かなくなりうる** —— 呼び手が結果を確かめる。IOKit の記号は dlsym で引く(リンクしない)

import Foundation

#if targetEnvironment(simulator)
private typealias NotifyFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                             UnsafeMutableRawPointer?, UInt32, UnsafeRawPointer?) -> Void
private typealias SetPropertyFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                  UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Bool
private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                   UnsafeMutableRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?,
                                                UInt32) -> UnsafeMutableRawPointer?
private typealias SetOutputEventFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                                     UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

/// IOHIDVirtualServiceClientCreate が受け取るコールバック表(この順・この数で並べる)
private struct VirtualServiceCallbacks {
    let notify: NotifyFn
    let setProperty: SetPropertyFn
    let copyProperty: CopyPropertyFn
    let copyEvent: CopyEventFn
    let setOutputEvent: SetOutputEventFn
}

private let hingeUsagePage = 0xFF61
private let hingeUsage = 0x5B
private let consumerUsagePage = 0x0C
/// Consumer Control の Menu = ホームボタン
private let consumerMenuUsage = 0x40

private let hingeProperties: [String: Any] = [
    "PrimaryUsagePage": hingeUsagePage, "PrimaryUsage": hingeUsage,
    "DeviceUsagePairs": [["DeviceUsagePage": hingeUsagePage, "DeviceUsage": hingeUsage]],
    "Product": "fleetest hinge", "Transport": "Virtual"]
private let buttonProperties: [String: Any] = [
    "PrimaryUsagePage": consumerUsagePage, "PrimaryUsage": 0x01,
    "DeviceUsagePairs": [["DeviceUsagePage": consumerUsagePage, "DeviceUsage": 0x01]],
    "Product": "fleetest buttons", "Transport": "Virtual", "Built-In": true]

private func copyProperty(_ table: [String: Any], _ key: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let key else { return nil }
    let name = Unmanaged<CFString>.fromOpaque(key).takeUnretainedValue() as String
    guard let value = table[name] else { return nil }
    return Unmanaged.passRetained(value as AnyObject).toOpaque()
}

// C の関数ポインタは文脈を捕捉できないので、サービスごとに表を分ける
private let hingeCallbacks = VirtualServiceCallbacks(
    notify: { _, _, _, _, _ in }, setProperty: { _, _, _, _, _ in false },
    copyProperty: { _, _, _, key in copyProperty(hingeProperties, key) },
    copyEvent: { _, _, _, _, _, _ in nil },
    setOutputEvent: { _, _, _, _ in Int32(bitPattern: 0xE000_02C7) })  // kIOReturnUnsupported
private let buttonCallbacks = VirtualServiceCallbacks(
    notify: { _, _, _, _, _ in }, setProperty: { _, _, _, _, _ in false },
    copyProperty: { _, _, _, key in copyProperty(buttonProperties, key) },
    copyEvent: { _, _, _, _, _, _ in nil },
    setOutputEvent: { _, _, _, _ in Int32(bitPattern: 0xE000_02C7) })
#endif

enum VirtualHID {
    #if targetEnvironment(simulator)
    private typealias CreateClient = @convention(c) (UnsafeRawPointer?, Int32, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetQueue = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Activate = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias CreateService = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?,
                                                      UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias Dispatch = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool
    private typealias Remove = @convention(c) (UnsafeMutableRawPointer?) -> Bool
    private typealias CreateVendorEvent = @convention(c) (UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32,
                                                          UnsafePointer<UInt8>?, CFIndex, UInt32) -> UnsafeMutableRawPointer?
    private typealias CreateKeyboardEvent = @convention(c) (UnsafeRawPointer?, UInt64, UInt32, UInt32, Bool,
                                                            UInt32) -> UnsafeMutableRawPointer?
    private typealias Serialize = @convention(c) (UnsafeRawPointer?, CFOptionFlags) -> UnsafeMutableRawPointer?

    private static let iokit: UnsafeMutableRawPointer? = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    /// 仮想サービスは種類ごとにランナーのプロセスで1つ(作るたびに HID のサービスが増える)。要求は直列に来るとは
    /// 限らないので lock の下で触る。@unchecked の根拠 = 可変の欄は lock の下でしか読み書きしない
    private final class Service: @unchecked Sendable {
        let lock = NSLock()
        let label: String
        let properties: [String: Any]
        let callbackTable: UnsafeMutablePointer<VirtualServiceCallbacks>
        var client: UnsafeMutableRawPointer?
        var service: UnsafeMutableRawPointer?
        let queue: DispatchQueue

        init(label: String, properties: [String: Any], callbacks: VirtualServiceCallbacks) {
            self.label = label
            self.properties = properties
            callbackTable = UnsafeMutablePointer<VirtualServiceCallbacks>.allocate(capacity: 1)
            callbackTable.initialize(to: callbacks)
            queue = DispatchQueue(label: "fleetest.virtualhid.\(label)")
        }

        /// 作ったばかりなら true(呼び手が照合待ちを払う)
        func ensure() throws -> Bool {
            guard service == nil else { return false }
            let handle = try VirtualHID.handle()
            let createClient = try symbol(handle, "IOHIDEventSystemClientCreateWithType", as: CreateClient.self)
            let setQueue = try symbol(handle, "IOHIDEventSystemClientSetDispatchQueue", as: SetQueue.self)
            let activate = try symbol(handle, "IOHIDEventSystemClientActivate", as: Activate.self)
            let createService = try symbol(handle, "IOHIDVirtualServiceClientCreate", as: CreateService.self)
            // 2 = 仮想サービスを登録できる種類のクライアント(第三者の実装と同じ値)
            guard let client = createClient(nil, 2, nil) else {
                throw BridgeError(500, "could not create the HID event system client (\(label))")
            }
            setQueue(client, Unmanaged.passUnretained(queue).toOpaque())
            activate(client)
            let dictionary = properties as NSDictionary
            guard let created = withExtendedLifetime(dictionary, {
                createService(client, Unmanaged.passUnretained(dictionary).toOpaque(),
                              UnsafeRawPointer(callbackTable), nil, nil)
            }) else {
                Unmanaged<CFTypeRef>.fromOpaque(client).release()
                throw BridgeError(500, "could not create the virtual HID service (\(label))")
            }
            self.client = client
            service = created
            return true
        }

        /// 流せなければ捨てて投げる(次の要求で作り直す)
        func dispatch(_ event: UnsafeMutableRawPointer) throws {
            let handle = try VirtualHID.handle()
            let dispatch = try symbol(handle, "IOHIDVirtualServiceClientDispatchEvent", as: Dispatch.self)
            guard dispatch(service, event) else {
                if let remove = try? symbol(handle, "IOHIDVirtualServiceClientRemove", as: Remove.self) {
                    _ = remove(service)
                }
                if let service { Unmanaged<CFTypeRef>.fromOpaque(service).release() }
                if let client { Unmanaged<CFTypeRef>.fromOpaque(client).release() }
                service = nil
                client = nil
                throw BridgeError(500, "the \(label) event was not dispatched"
                    + " (the virtual HID service is recreated on the next request)")
            }
        }
    }

    private static let hinge = Service(label: "hinge", properties: hingeProperties, callbacks: hingeCallbacks)
    private static let buttons = Service(label: "buttons", properties: buttonProperties, callbacks: buttonCallbacks)
    /// 作った仮想サービスがイベント系に照合されるまでの待ち(秒)。待たずに送ると最初の1回が届かない
    /// (第三者の実装が 500ms で揃えている。サービスごとに最初の1回だけ払う)
    private static let firstServiceSettleSeconds: Double = 0.5
    /// ボタンを押してから離すまで(秒)。押したままの判定(長押し)に届かない短さ
    private static let buttonPressSeconds: Double = 0.1

    private static func handle() throws -> UnsafeMutableRawPointer {
        guard let iokit else { throw BridgeError(422, "IOKit could not be opened in this simulator runtime") }
        return iokit
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as: T.Type) throws -> T {
        guard let address = dlsym(handle, name) else {
            throw BridgeError(422, "IOKit has no \(name) in this simulator runtime")
        }
        return unsafeBitCast(address, to: T.self)
    }
    #endif

    /// ヒンジ角を送る。送れたら戻る(画面の切り替わりは待たない)
    static func sendHinge(degrees: Double) throws {
        #if targetEnvironment(simulator)
        let service = hinge
        service.lock.lock()
        defer { service.lock.unlock() }
        if try service.ensure() { Thread.sleep(forTimeInterval: firstServiceSettleSeconds) }
        let handle = try handle()
        let serialize = try symbol(handle, "IOCFSerialize", as: Serialize.self)
        let createEvent = try symbol(handle, "IOHIDEventCreateVendorDefinedEvent", as: CreateVendorEvent.self)
        let payload: NSDictionary = ["source": "hinge-slider-control", "type": "range", "value": degrees]
        guard let dataPointer = withExtendedLifetime(payload, {
            serialize(Unmanaged.passUnretained(payload).toOpaque(), 0)
        }) else {
            throw BridgeError(500, "could not serialize the hinge event")
        }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeRetainedValue()
        guard let event = createEvent(nil, mach_absolute_time(), UInt32(hingeUsagePage), UInt32(hingeUsage), 0,
                                      CFDataGetBytePtr(data), CFDataGetLength(data), 0) else {
            throw BridgeError(500, "could not create the hinge event")
        }
        defer { Unmanaged<CFTypeRef>.fromOpaque(event).release() }
        try service.dispatch(event)
        #else
        throw BridgeError(422, "folding a physical device is not supported (fold it by hand)")
        #endif
    }

    /// ホームボタンを1回押す(押して離す)。押せたら戻る(ホームへ出たかは呼び手が確かめる)
    static func pressHomeButton() throws {
        #if targetEnvironment(simulator)
        let service = buttons
        service.lock.lock()
        defer { service.lock.unlock() }
        if try service.ensure() { Thread.sleep(forTimeInterval: firstServiceSettleSeconds) }
        let createKey = try symbol(try handle(), "IOHIDEventCreateKeyboardEvent", as: CreateKeyboardEvent.self)
        for down in [true, false] {
            guard let event = createKey(nil, mach_absolute_time(), UInt32(consumerUsagePage),
                                        UInt32(consumerMenuUsage), down, 0) else {
                throw BridgeError(500, "could not create the home button event")
            }
            defer { Unmanaged<CFTypeRef>.fromOpaque(event).release() }
            try service.dispatch(event)
            if down { Thread.sleep(forTimeInterval: buttonPressSeconds) }
        }
        #else
        throw BridgeError(422, "the virtual home button is only available on a simulator")
        #endif
    }
}
