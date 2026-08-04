import SwiftSyntax

/// Derives TL declarations from Swift syntax and computes their CRC32
/// constructor numbers, mirroring the rules at
/// <https://core.telegram.org/mtproto/TL>.
enum SchemaBuilder {
  // MARK: CRC32

  /// Standard CRC-32 (IEEE 802.3, the zlib variant) — TL constructor
  /// numbers are the CRC32 of the normalized declaration text.
  static func crc32(_ string: String) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in string.utf8 {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
      }
    }
    return ~crc
  }

  /// Normalizes a TL declaration before hashing: removes `;` and
  /// parentheses, strips an explicit `#xxxxxxxx` constructor number from
  /// the combinator name, and collapses whitespace.
  static func normalize(_ declaration: String) -> String {
    let mapped = declaration.map { (ch: Character) -> Character in
      switch ch {
      case ";", "(", ")":
        return " "
      default:
        return ch
      }
    }
    var tokens = String(mapped)
      .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
      .map(String.init)
    if let first = tokens.first, let hashIndex = first.firstIndex(of: "#") {
      tokens[0] = String(first[..<hashIndex])
    }
    return tokens.joined(separator: " ")
  }

  static func constructorID(forDeclaration declaration: String) -> UInt32 {
    crc32(normalize(declaration))
  }

  // MARK: Name conversion

  /// `firstName` → `first_name`, `userID` → `user_id`, `p2p` → `p2p`.
  static func snakeCase(_ name: String) -> String {
    let characters = Array(name)
    var result = ""
    for (index, character) in characters.enumerated() {
      if character.isUppercase {
        let previousIsLowerOrDigit =
          index > 0
          && (characters[index - 1].isLowercase || characters[index - 1].isNumber)
        let previousIsUpper = index > 0 && characters[index - 1].isUppercase
        let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
        if previousIsLowerOrDigit || (previousIsUpper && nextIsLower) {
          result.append("_")
        }
        result.append(contentsOf: character.lowercased())
      } else {
        result.append(character)
      }
    }
    return result
  }

  /// `InputPeer` → `inputPeer` (TL combinator names start lowercase).
  static func lowercasedFirst(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.lowercased() + name.dropFirst()
  }

  // MARK: Swift type → TL type

  /// Maps a (non-optional) Swift type to its TL type name for use in a
  /// derived declaration. Returns `nil` for types that cannot be expressed
  /// (the caller diagnoses with context).
  static func tlTypeName(_ type: TypeSyntax) -> String? {
    let (wrapped, _) = unwrapOptional(type)
    if let array = wrapped.as(ArrayTypeSyntax.self) {
      guard let element = tlTypeName(array.element) else { return nil }
      return "Vector<\(element)>"
    }
    if let identifier = wrapped.as(IdentifierTypeSyntax.self) {
      let name = identifier.name.text
      if identifier.genericArgumentClause != nil {
        // `Array<T>` and other generics: require sugar / explicit ids.
        return nil
      }
      switch name {
      case "Int32", "UInt32":
        return "int"
      case "Int64", "UInt64", "Int":
        return "long"
      case "Double":
        return "double"
      case "String":
        return "string"
      case "Data":
        return "bytes"
      case "Bool":
        return "Bool"
      case "TLInt128":
        return "int128"
      case "TLInt256":
        return "int256"
      default:
        // A user-defined boxed type: keep the Swift name, which by
        // TL convention starts uppercase for boxed types.
        return name
      }
    }
    if let member = wrapped.as(MemberTypeSyntax.self) {
      return member.name.text
    }
    return nil
  }
}
