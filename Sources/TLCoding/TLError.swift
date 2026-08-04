/// Errors thrown while decoding MTProto (TL) binary data.
public enum TLError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The reader ran out of input bytes.
  case endOfData(needed: Int, remaining: Int)
  /// A boxed value started with a constructor number that does not match
  /// any of the constructors expected at this position.
  case unexpectedConstructor(found: UInt32, expected: [UInt32])
  /// The input contained a value that is structurally invalid
  /// (e.g. a negative vector count, an invalid string length prefix,
  /// or bytes that are not valid UTF-8 for a `string`).
  case invalidValue(String)

  public var description: String {
    switch self {
    case .endOfData(let needed, let remaining):
      return "TLError.endOfData: needed \(needed) byte(s), only \(remaining) remaining"
    case .unexpectedConstructor(let found, let expected):
      let list = expected.map { "0x" + String($0, radix: 16) }.joined(separator: ", ")
      return
        "TLError.unexpectedConstructor: found 0x\(String(found, radix: 16)), expected one of [\(list)]"
    case .invalidValue(let reason):
      return "TLError.invalidValue: \(reason)"
    }
  }
}
