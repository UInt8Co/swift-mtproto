import Crypto

// Vector hashing for the list RPCs keyed by strings — emoji reactions, language
// packs — rather than by numeric ids.

extension VectorHash {
  /// The spec's string→long conversion: first 8 bytes of `MD5(utf8)`, big-endian.
  public static func longID(of string: String) -> Int64 {
    var digest = Insecure.MD5()
    digest.update(data: Array(string.utf8))
    let bytes = Array(digest.finalize())  // 16 bytes
    var value: UInt64 = 0
    for byte in bytes.prefix(8) { value = (value << 8) | UInt64(byte) }
    return Int64(bitPattern: value)
  }

  /// Folds one string id (via ``longID(of:)``) into the running hash.
  public mutating func combine(string: String) {
    combine(Self.longID(of: string))
  }

  /// Folds a sequence of string ids and returns the wire hash.
  public static func compute<S: Sequence>(strings: S) -> Int64 where S.Element == String {
    var hash = VectorHash()
    for string in strings { hash.combine(string: string) }
    return hash.value
  }

  /// Folds string `ids` into a hash and compares it against `clientHash`.
  public static func state<S: Sequence>(clientHash: Int64, overStrings ids: S) -> VectorHashState
  where S.Element == String {
    state(clientHash: clientHash, current: compute(strings: ids))
  }
}
