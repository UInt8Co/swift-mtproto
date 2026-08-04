extension Sequence where Element == UInt8 {
  /// Lowercase, two-hex-digits-per-byte encoding, e.g. `[0x0a, 0xff]` → `"0aff"`.
  ///
  /// Hand-rolled because `String(format:)` needs full Foundation.
  public var hexEncodedString: String {
    let digits = Array("0123456789abcdef")
    var chars: [Character] = []
    chars.reserveCapacity(underestimatedCount * 2)
    for byte in self {
      chars.append(digits[Int(byte >> 4)])
      chars.append(digits[Int(byte & 0x0f)])
    }
    return String(chars)
  }
}
