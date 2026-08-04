import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct TLCodingPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    TLObjectMacro.self,
    TLFlagsEquatableMacro.self,
    TLTypeMacro.self,
    TLMarkerMacro.self,
  ]
}
