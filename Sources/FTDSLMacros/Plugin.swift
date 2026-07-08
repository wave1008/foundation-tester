// Plugin.swift
// コンパイラプラグインのエントリポイント。

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct FTDSLPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TestClassMacro.self,
        TestMacro.self,
        DeletedMacro.self,
    ]
}
