#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A cursor over MTProto (TL) serialized data.
///
/// All values are read in little-endian byte order. Every read validates the
/// remaining length and throws ``TLError/endOfData(needed:remaining:)`` when
/// the input is truncated.
public struct TLReader: Sendable {
  private let bytes: [UInt8]
  /// Current read position, in bytes from the start of the input.
  public private(set) var offset: Int

  public init(_ data: Data) {
    self.bytes = [UInt8](data)
    self.offset = 0
  }

  public init(_ bytes: [UInt8]) {
    self.bytes = bytes
    self.offset = 0
  }

  /// The number of bytes that have not been consumed yet.
  public var bytesRemaining: Int { bytes.count - offset }

  /// Whether the entire input has been consumed.
  public var isAtEnd: Bool { offset >= bytes.count }

  private func require(_ count: Int) throws {
    guard bytesRemaining >= count else {
      throw TLError.endOfData(needed: count, remaining: bytesRemaining)
    }
  }

  // MARK: Raw

  /// Consumes `count` raw bytes.
  public mutating func readRawBytes(_ count: Int) throws -> Data {
    try require(count)
    defer { offset += count }
    return Data(bytes[offset..<offset + count])
  }

  /// Skips `count` bytes.
  public mutating func skip(_ count: Int) throws {
    try require(count)
    offset += count
  }

  public mutating func readUInt8() throws -> UInt8 {
    try require(1)
    defer { offset += 1 }
    return bytes[offset]
  }

  // MARK: Fixed-width integers (`int`, `long`)

  public mutating func readUInt32() throws -> UInt32 {
    try require(4)
    defer { offset += 4 }
    return UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  public mutating func readInt32() throws -> Int32 {
    Int32(bitPattern: try readUInt32())
  }

  public mutating func readUInt64() throws -> UInt64 {
    let low = try readUInt32()
    let high = try readUInt32()
    return UInt64(low) | UInt64(high) << 32
  }

  public mutating func readInt64() throws -> Int64 {
    Int64(bitPattern: try readUInt64())
  }

  /// Returns the next 32-bit word (e.g. a constructor number) without
  /// consuming it.
  public func peekUInt32() throws -> UInt32 {
    try require(4)
    return UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  // MARK: `double`

  public mutating func readDouble() throws -> Double {
    Double(bitPattern: try readUInt64())
  }

  // MARK: `int128` / `int256`

  public mutating func readInt128() throws -> TLInt128 {
    let low = try readUInt64()
    let high = try readUInt64()
    return TLInt128(low: low, high: high)
  }

  public mutating func readInt256() throws -> TLInt256 {
    let w0 = try readUInt64()
    let w1 = try readUInt64()
    let w2 = try readUInt64()
    let w3 = try readUInt64()
    return TLInt256(w0: w0, w1: w1, w2: w2, w3: w3)
  }

  // MARK: `string` / `bytes`

  /// Consumes a TL `string`/`bytes` value, including its alignment padding.
  public mutating func readBytes() throws -> Data {
    let first = try readUInt8()
    let length: Int
    let headerSize: Int
    switch first {
    case 0...253:
      length = Int(first)
      headerSize = 1
    case 254:
      let b0 = try readUInt8()
      let b1 = try readUInt8()
      let b2 = try readUInt8()
      length = Int(b0) | Int(b1) << 8 | Int(b2) << 16
      headerSize = 4
    default:
      throw TLError.invalidValue("invalid TL string length prefix 0xFF")
    }
    let payload = try readRawBytes(length)
    let padding = (4 - (headerSize + length) % 4) % 4
    try skip(padding)
    return payload
  }

  /// Consumes a TL `string` value and decodes it as UTF-8.
  public mutating func readString() throws -> String {
    let payload = try readBytes()
    guard let string = String(bytes: payload, encoding: .utf8) else {
      throw TLError.invalidValue("TL string is not valid UTF-8")
    }
    return string
  }
}
