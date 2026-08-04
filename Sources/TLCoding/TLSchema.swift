import MTProtoUtils

/// Computing TL constructor numbers: per
/// <https://core.telegram.org/mtproto/TL>, the CRC32 of a normalized declaration.
/// See <doc:ConstructorNumbers>.
public enum TLSchema {
  /// The constructor number of a TL declaration, normalized first — so both
  /// `"user id:int first_name:string = User"` and
  /// `"user#d23c81a3 id:int first_name:string = User;"` yield `0xd23c81a3`.
  public static func constructorID(forDeclaration declaration: String) -> UInt32 {
    crc32(of: normalize(declaration))
  }

  /// Normalizes a TL declaration before hashing:
  /// removes `;`, removes parentheses, strips an explicit `#xxxxxxxx`
  /// constructor number, and collapses whitespace runs to single spaces.
  public static func normalize(_ declaration: String) -> String {
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

  /// Standard CRC-32 (IEEE 802.3, the zlib variant).
  public static func crc32(of bytes: some Sequence<UInt8>) -> UInt32 {
    CRC32.checksum(of: bytes)
  }

  /// CRC-32 of the UTF-8 bytes of `string`.
  public static func crc32(of string: String) -> UInt32 {
    crc32(of: string.utf8)
  }
}
