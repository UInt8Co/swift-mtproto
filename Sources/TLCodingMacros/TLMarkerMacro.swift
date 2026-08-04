import SwiftSyntax
import SwiftSyntaxMacros

/// Shared implementation of the marker attributes `@TLCase`, `@TLFlags`,
/// `@TLConditional`, `@TLBare`, `@TLBareElements` and `@TLOmit`.
///
/// These macros expand to nothing themselves; they only annotate the syntax
/// tree so that `@TLObject` (expanded on the enclosing type) can read them.
public struct TLMarkerMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    []
  }
}
