// Descriptors.swift
// テストクラス/シナリオのメタデータと、objc ランタイムによるシナリオ自動発見。
// @TestClass マクロがこれらへの conformance・登録クラスを生成する(手書きも可能)。

import Foundation
import ObjectiveC

// FTDSL を import すれば FTCore の型(FTSwipeDirection 等)もそのまま使えるようにする
@_exported import FTCore

/// 1 シナリオ(@Test メソッド)のメタデータ
public struct FTScenarioDescriptor {
    /// メソッド名(日本語可)
    public let name: String
    /// @Test の引数タイトル
    public let title: String
    /// テストクラスの新規インスタンスを作ってメソッドを呼ぶクロージャ(マクロ生成)
    public let run: () -> Void

    public init(name: String, title: String, run: @escaping () -> Void) {
        self.name = name
        self.title = title
        self.run = run
    }
}

/// テストクラス(@TestClass)のメタデータ
public struct FTTestClassDescriptor {
    public let className: String
    /// 対象アプリの bundle ID / パッケージ名
    public let app: String
    /// "ios" / "android" / nil(両OS対応)
    public let platform: String?
    public let scenarios: [FTScenarioDescriptor]

    public init(className: String, app: String, platform: String?, scenarios: [FTScenarioDescriptor]) {
        self.className = className
        self.app = app
        self.platform = platform
        self.scenarios = scenarios
    }
}

/// @TestClass が生成する conformance。手書きでの適合も可能(マクロはこの糖衣)
public protocol FTTestClassDefinition {
    static var ftDescriptor: FTTestClassDescriptor { get }
}

/// objc ランタイム発見用の基底クラス。@TestClass が __FTReg_<クラス名> サブクラスを生成する
open class FTScenarioRegistration: NSObject {
    open class var descriptor: FTTestClassDescriptor {
        fatalError("FTScenarioRegistration.descriptor を override してください")
    }
}

/// シナリオの一意 ID: クラス名.メソッド名
public struct ScenarioID: CustomStringConvertible, Equatable {
    public let className: String
    public let methodName: String
    public var description: String { "\(className).\(methodName)" }

    public init(className: String, methodName: String) {
        self.className = className
        self.methodName = methodName
    }
}

public enum ScenarioDiscovery {
    /// プロセスに読み込まれた全 FTScenarioRegistration 派生クラスから descriptor を収集する。
    /// 重要: 未実現(unrealized)クラスへメッセージを送ると壊れるクラスがあるため、
    /// 判定は class_getSuperclass の C API 走査のみで行う(isSubclass(of:) 等は使わない)。
    public static func allTestClasses() -> [FTTestClassDescriptor] {
        var count: UInt32 = 0
        guard let listPtr = objc_copyClassList(&count) else { return [] }
        defer { free(UnsafeMutableRawPointer(listPtr)) }
        let buffer = UnsafeBufferPointer(start: listPtr, count: Int(count))

        var result: [FTTestClassDescriptor] = []
        for cls in buffer {
            var superclass: AnyClass? = class_getSuperclass(cls)
            var isRegistration = false
            while let s = superclass {
                if s == FTScenarioRegistration.self {
                    isRegistration = true
                    break
                }
                superclass = class_getSuperclass(s)
            }
            guard isRegistration, let regType = cls as? FTScenarioRegistration.Type else { continue }
            result.append(regType.descriptor)
        }
        return result.sorted { $0.className < $1.className }
    }

    /// ID(クラス名.メソッド名)でシナリオを探す。クラス名のみでシナリオが 1 つならそれを返す
    public static func find(id: String) -> (testClass: FTTestClassDescriptor, scenario: FTScenarioDescriptor)? {
        let classes = allTestClasses()
        for testClass in classes {
            for scenario in testClass.scenarios
            where "\(testClass.className).\(scenario.name)" == id {
                return (testClass, scenario)
            }
        }
        if let testClass = classes.first(where: { $0.className == id }),
           testClass.scenarios.count == 1 {
            return (testClass, testClass.scenarios[0])
        }
        return nil
    }
}
