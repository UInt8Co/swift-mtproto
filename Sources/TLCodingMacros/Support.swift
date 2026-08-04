import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Diagnostics

struct TLMacroDiagnostic: DiagnosticMessage {
  let message: String
  let diagnosticID: MessageID
  let severity: DiagnosticSeverity

  init(_ message: String, id: String, severity: DiagnosticSeverity = .error) {
    self.message = message
    self.diagnosticID = MessageID(domain: "TLCodingMacros", id: id)
    self.severity = severity
  }
}

/// Builds a throwable error that surfaces as a compiler diagnostic anchored
/// at `node`.
func macroError(_ node: some SyntaxProtocol, _ message: String, id: String = "invalid")
  -> DiagnosticsError
{
  DiagnosticsError(diagnostics: [
    Diagnostic(node: Syntax(node), message: TLMacroDiagnostic(message, id: id))
  ])
}

// MARK: - Literal parsing

/// Parses an integer literal expression (decimal, `0x`, `0o`, `0b`, with `_`
/// separators) into a fixed-width integer.
func parseIntegerLiteral<T: FixedWidthInteger>(_ expr: ExprSyntax, as type: T.Type) -> T? {
  guard let literal = expr.as(IntegerLiteralExprSyntax.self) else { return nil }
  var text = String(literal.literal.text.lazy.filter { $0 != "_" })
  var radix = 10
  if text.hasPrefix("0x") || text.hasPrefix("0X") {
    radix = 16
    text = String(text.dropFirst(2))
  } else if text.hasPrefix("0o") {
    radix = 8
    text = String(text.dropFirst(2))
  } else if text.hasPrefix("0b") {
    radix = 2
    text = String(text.dropFirst(2))
  }
  return T(text, radix: radix)
}

/// Parses a static string literal (no interpolation segments).
func parseStringLiteral(_ expr: ExprSyntax) -> String? {
  guard let literal = expr.as(StringLiteralExprSyntax.self) else { return nil }
  var result = ""
  for segment in literal.segments {
    guard case .stringSegment(let text) = segment else { return nil }
    result += text.content.text
  }
  return result
}

// MARK: - Attribute helpers

/// The simple (unqualified) name of an attribute, e.g. `TLConditional` for
/// both `@TLConditional(...)` and `@TLCoding.TLConditional(...)`.
func attributeName(_ attribute: AttributeSyntax) -> String {
  if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
    return identifier.name.text
  }
  if let member = attribute.attributeName.as(MemberTypeSyntax.self) {
    return member.name.text
  }
  return attribute.attributeName.trimmedDescription
}

/// Finds the first attribute with the given simple name.
func attribute(named name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
  for element in attributes {
    if case .attribute(let attribute) = element, attributeName(attribute) == name {
      return attribute
    }
  }
  return nil
}

/// The labeled argument list of an attribute, if any.
func attributeArguments(_ attribute: AttributeSyntax) -> LabeledExprListSyntax? {
  guard case .argumentList(let list)? = attribute.arguments else { return nil }
  return list
}

// MARK: - Declaration helpers

/// Whether a pattern binding describes a stored property (observers like
/// `willSet`/`didSet` still count as stored; `get`/`set` do not).
func isStoredBinding(_ binding: PatternBindingSyntax) -> Bool {
  guard let accessorBlock = binding.accessorBlock else { return true }
  switch accessorBlock.accessors {
  case .getter:
    return false
  case .accessors(let list):
    return list.allSatisfy { accessor in
      switch accessor.accessorSpecifier.tokenKind {
      case .keyword(.willSet), .keyword(.didSet):
        return true
      default:
        return false
      }
    }
  }
}

func hasModifier(_ decl: some WithModifiersSyntax, _ keyword: Keyword) -> Bool {
  decl.modifiers.contains { $0.name.tokenKind == .keyword(keyword) }
}

/// Strips one level of optionality from a type, returning the wrapped type
/// and whether the type was optional (`T?` or `Optional<T>`).
func unwrapOptional(_ type: TypeSyntax) -> (wrapped: TypeSyntax, wasOptional: Bool) {
  if let optional = type.as(OptionalTypeSyntax.self) {
    return (optional.wrappedType, true)
  }
  if let identifier = type.as(IdentifierTypeSyntax.self),
    identifier.name.text == "Optional",
    let clause = identifier.genericArgumentClause,
    let first = clause.arguments.first,
    let wrapped = first.argument.as(TypeSyntax.self)
  {
    return (wrapped, true)
  }
  return (type, false)
}

/// Builds the `: P1, P2` clause for a generated extension. Implied
/// conformances are not synthesized for macro-generated extensions, so each
/// protocol the compiler asked for is listed explicitly.
func conformanceClause(_ protocols: [TypeSyntax], excluding excluded: Set<String> = [])
  -> String
{
  let names =
    protocols
    .map(\.trimmedDescription)
    .filter { !excluded.contains($0) }
  return names.isEmpty ? "" : ": " + names.joined(separator: ", ")
}

func formatHex(_ value: UInt32) -> String {
  let hex = String(value, radix: 16)
  return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
}
