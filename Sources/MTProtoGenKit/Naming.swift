/// The mechanical TL → Swift identifier mapping, so the same schema always
/// produces the same names. See <doc:GeneratedShape>.
@_spi(GeneratorInternals) public enum Naming {
  /// Swift keywords that cannot be used as bare identifiers. `self` is excluded —
  /// see ``escaped(_:)``.
  static let reservedKeywords: Set<String> = [
    "as", "associatedtype", "async", "await", "break", "case", "catch",
    "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
    "extension", "fallthrough", "false", "fileprivate", "for", "func",
    "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
    "nil", "operator", "precedencegroup", "private", "protocol", "public",
    "repeat", "rethrows", "return", "static", "struct", "subscript", "super",
    "switch", "throw", "throws", "true", "try", "typealias", "var", "where",
    "while", "Self", "Any",
  ]

  /// `first_name` → `firstName`. Existing capitalization is preserved.
  @_spi(GeneratorInternals) public static func camelCase(_ name: String) -> String {
    let parts = name.split(separator: "_", omittingEmptySubsequences: true)
    guard let first = parts.first else { return name }
    return String(first) + parts.dropFirst().map(capitalizedFirst).joined()
  }

  @_spi(GeneratorInternals) public static func capitalizedFirst(_ name: some StringProtocol) -> String {
    guard let first = name.first else { return String(name) }
    return first.uppercased() + name.dropFirst()
  }

  @_spi(GeneratorInternals) public static func lowercasedFirst(_ name: some StringProtocol) -> String {
    guard let first = name.first else { return String(name) }
    return first.lowercased() + name.dropFirst()
  }

  /// Flattens a possibly namespaced TL name into one capitalized identifier:
  /// `auth.sentCode` → `AuthSentCode`, `user` → `User`.
  @_spi(GeneratorInternals) public static func flattened(_ tlName: String) -> String {
    tlName.split(separator: ".").map { capitalizedFirst(camelCase(String($0))) }.joined()
  }

  /// Escapes a Swift keyword with backticks. `self` becomes `self_`: a backticked
  /// `self` parameter would shadow the instance inside an initializer.
  @_spi(GeneratorInternals) public static func escaped(_ identifier: String) -> String {
    if identifier == "self" { return "self_" }
    if reservedKeywords.contains(identifier) { return "`\(identifier)`" }
    return identifier
  }

  /// Swift property / parameter name for a TL field name.
  @_spi(GeneratorInternals) public static func propertyName(_ tlFieldName: String) -> String {
    escaped(camelCase(tlFieldName))
  }

  /// Swift enum name for a TL namespace: `auth` → `Auth`.
  @_spi(GeneratorInternals) public static func namespaceEnumName(_ tlNamespace: String) -> String {
    capitalizedFirst(camelCase(tlNamespace))
  }

  /// Swift enum case name for a constructor predicate.
  @_spi(GeneratorInternals) public static func caseName(_ tlPredicate: String) -> String {
    escaped(lowercasedFirst(flattened(tlPredicate)))
  }

  /// The TL namespace of a combinator name (`auth.sendCode` → `auth`),
  /// or `nil` for the global namespace.
  @_spi(GeneratorInternals) public static func namespace(of tlName: String) -> String? {
    guard let dot = tlName.firstIndex(of: ".") else { return nil }
    return String(tlName[..<dot])
  }

  /// The name within its namespace (`auth.sendCode` → `sendCode`).
  @_spi(GeneratorInternals) public static func localName(of tlName: String) -> String {
    guard let dot = tlName.firstIndex(of: ".") else { return tlName }
    return String(tlName[tlName.index(after: dot)...])
  }

  /// `0xa677244f`-style lowercase hex literal for a constructor number.
  @_spi(GeneratorInternals) public static func hexLiteral(_ value: UInt32) -> String {
    var digits = String(value, radix: 16)
    if digits.count < 8 {
      digits = String(repeating: "0", count: 8 - digits.count) + digits
    }
    return "0x" + digits
  }
}
