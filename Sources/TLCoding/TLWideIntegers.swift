#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Formats `value` as exactly 16 zero-padded lowercase hexadecimal digits.
///
/// Used instead of `String(format:)`, which lives in full `Foundation` and is
/// unavailable when only `FoundationEssentials` is imported.
private func hex16(_ value: UInt64) -> String {
  let digits = String(value, radix: 16)
  return String(repeating: "0", count: 16 - digits.count) + digits
}

/// A 128-bit value (TL `int128`), stored as two little-endian 64-bit words.
///
/// MTProto uses `int128` for nonces and message keys; the value is written to
/// the wire as 16 raw bytes in little-endian order (`low` first).
public struct TLInt128: Hashable, Sendable {
  /// The least significant 64 bits.
  public var low: UInt64
  /// The most significant 64 bits.
  public var high: UInt64

  public init(low: UInt64, high: UInt64) {
    self.low = low
    self.high = high
  }

  public static let zero = TLInt128(low: 0, high: 0)

  /// A cryptographically random value (e.g. a handshake nonce).
  public static func random() -> TLInt128 {
    var generator = SystemRandomNumberGenerator()
    return TLInt128(low: generator.next(), high: generator.next())
  }
}

extension TLInt128: CustomStringConvertible {
  public var description: String {
    "0x" + hex16(high) + hex16(low)
  }
}

extension TLInt128: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeInt128(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readInt128()
  }
}

/// A 256-bit value (TL `int256`), stored as four little-endian 64-bit words
/// (`w0` is least significant). Written to the wire as 32 raw bytes.
public struct TLInt256: Hashable, Sendable {
  public var w0: UInt64
  public var w1: UInt64
  public var w2: UInt64
  public var w3: UInt64

  public init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
    self.w0 = w0
    self.w1 = w1
    self.w2 = w2
    self.w3 = w3
  }

  public static let zero = TLInt256(w0: 0, w1: 0, w2: 0, w3: 0)

  /// A cryptographically random value (e.g. `new_nonce` in the handshake).
  public static func random() -> TLInt256 {
    var generator = SystemRandomNumberGenerator()
    return TLInt256(
      w0: generator.next(), w1: generator.next(), w2: generator.next(), w3: generator.next())
  }
}

extension TLInt256: CustomStringConvertible {
  public var description: String {
    "0x" + hex16(w3) + hex16(w2) + hex16(w1) + hex16(w0)
  }
}

extension TLInt256: TLEncodable, TLDecodable {
  public func tlEncode(to writer: inout TLWriter) {
    writer.writeInt256(self)
  }

  public init(tlFrom reader: inout TLReader) throws {
    self = try reader.readInt256()
  }
}
